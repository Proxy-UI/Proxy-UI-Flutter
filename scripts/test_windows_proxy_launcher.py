"""Run with python3 scripts/test_windows_proxy_launcher.py.

Set POWERSHELL to a pwsh path on macOS/Linux. These platforms validate syntax
and the Windows runtime's argument/environment generation; Win32 process lookup
is stubbed only in that non-Windows check. Windows additionally exercises real
COM shortcut creation, reload, independent edits, and failed-save preservation.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "assets/launchers/windows"
POWERSHELL = os.environ.get("POWERSHELL") or shutil.which("powershell") or shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL, "PowerShell is required")
class WindowsLaunchers(unittest.TestCase):
    def run_ps(self, script, *args, input_data=None):
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-File", str(script), *args],
            input=json.dumps(input_data or {}), text=True, encoding="utf-8",
            capture_output=True, timeout=30,
        )

    def test_syntax_and_proxy_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            wrapper = folder / "check.ps1"
            wrapper.write_text(
                "param($Source, $Config)\n"
                "$errors = $null; $tokens = $null\n"
                "foreach ($script in @('manage.ps1','applications.ps1','runtime.ps1')) {\n"
                "[void][System.Management.Automation.Language.Parser]::ParseFile("
                "(Join-Path $Source $script), [ref]$tokens, [ref]$errors)\n"
                "if ($errors.Count) { throw ($errors | Out-String) }\n}\n"
                + ("" if sys.platform == "win32" else "function Get-CimInstance { @() }\n")
                + "& (Join-Path $Source 'runtime.ps1') -Config $Config -Check\nexit $LASTEXITCODE\n",
                encoding="utf-8-sig",
            )
            target = folder / "App with spaces.exe"
            target.touch()
            config = folder / "launcher.json"
            settings = dict(schemaVersion=1, appPath=str(target), mode="chromium",
                            port=10801, bypassRules=["*oa*", ".oa.com", ".woa.com"])
            config.write_text(json.dumps(settings), encoding="utf-8")
            result = self.run_ps(wrapper, str(ASSETS), str(config))
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["launchArguments"], [
                "--proxy-server=http://127.0.0.1:10801",
                "--proxy-bypass-list=localhost;127.0.0.1;[::1];*oa*;oa.com;*.oa.com;woa.com;*.woa.com",
            ])
            self.assertEqual(report["noProxy"], "localhost,127.0.0.1,::1,.oa.com,.woa.com")
            settings["bypassRules"] = ["host;--proxy-server=evil"]
            config.write_text(json.dumps(settings))
            self.assertNotEqual(self.run_ps(wrapper, str(ASSETS), str(config)).returncode, 0)

    def test_discovery_deduplicates_versioned_installs(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            for version in ("app-1.0", "app-2.0"):
                (folder / version).mkdir()
                (folder / version / "Claude.exe").touch()
            old = folder / "app-1.0" / "Claude.exe"
            os.utime(old, (1, 1))
            wrapper = folder / "discover.ps1"
            wrapper.write_text(
                "param($Source,$Root)\n$ErrorActionPreference = 'Stop'\n"
                ". (Join-Path $Source 'applications.ps1')\n"
                "$install = @{root=$Root; name='Claude'; id='com.anthropic.claudefordesktop'; executables=@('Claude.exe')}\n"
                "$apps = @(Find-LauncherApplications -Installations @($install,$install))\n"
                "ConvertTo-Json -InputObject $apps -Depth 5\n",
                encoding="utf-8-sig",
            )
            result = self.run_ps(wrapper, str(ASSETS), str(folder))
            self.assertEqual(result.returncode, 0, result.stderr)
            found = json.loads(result.stdout)
            self.assertEqual(len(found), 1)
            self.assertTrue(Path(found[0]["appPath"]).samefile(folder / "app-2.0" / "Claude.exe"))
            self.assertEqual(found[0]["mode"], "chromium")

    @unittest.skipUnless(sys.platform == "win32", "Requires Windows shell/COM")
    def test_shortcut_roundtrip_and_failed_edit(self):
        created = []
        manage = ASSETS / "manage.ps1"

        def call(action, data):
            result = self.run_ps(manage, "-Action", action, input_data=data)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout) if result.stdout.strip() else None

        try:
            initial = dict(name="CipherRelay test launcher", appPath=sys.executable,
                           mode="environment", port=10801, bypassRules=[".woa.com"])
            first = call("Save", initial)
            created.append(first["id"])
            second = call("Save", dict(initial, bypassRules=[".example.test"]))
            created.append(second["id"])
            self.assertTrue(Path(first["launcherPath"]).is_file())
            updated = call("Save", dict(initial, id=first["id"], bypassRules=[]))
            self.assertEqual(updated["launcherPath"], first["launcherPath"])
            failed = self.run_ps(manage, "-Action", "Save", input_data=dict(
                initial, id=first["id"], appPath="C:\\missing-test-app.exe"))
            self.assertNotEqual(failed.returncode, 0)
            entries = {item["id"]: item for item in call("List", {})}
            self.assertEqual(entries[first["id"]]["bypassRules"], [])
            self.assertEqual(entries[second["id"]]["bypassRules"], [".example.test"])
        finally:
            for identifier in created:
                call("Trash", dict(id=identifier))


if __name__ == "__main__":
    unittest.main()
