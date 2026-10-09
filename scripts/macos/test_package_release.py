"""Fail-closed release checks; no Apple or GitHub credentials required."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import package_release


class ReleaseSafetyTests(unittest.TestCase):
    def test_mounted_app_assessment_failure_is_fatal_and_detaches_image(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            info = {"CFBundleIdentifier": "com.example.test", "CFBundleExecutable": "CipherRelay",
                    "CFBundleShortVersionString": "1.2.22", "CFBundleVersion": "49"}
            calls = []

            def run(*args):
                calls.append(args)
                if args[:2] == ("hdiutil", "attach"):
                    contents = work / "mounted/CipherRelay.app/Contents"
                    contents.mkdir(parents=True)
                    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
                if args[:2] == ("codesign", "--display"):
                    return "TeamIdentifier=TEAM\nAuthority=Developer ID Application: Test\n"
                if args[0] == "spctl":
                    raise RuntimeError("Gatekeeper rejected mounted application")
                return ""

            with patch.object(package_release, 'run', side_effect=run):
                with self.assertRaisesRegex(RuntimeError, 'Gatekeeper rejected'):
                    package_release.verify_mounted_app(work / 'test.dmg', work, info, 'TEAM', work)
            self.assertEqual(calls[-1], ("hdiutil", "detach", work / "mounted"))
            self.assertFalse((work / 'mounted-app-verification.txt').exists())

    def test_rejected_notarization_preserves_submission_and_diagnostics(self):
        result = subprocess.CompletedProcess([], 1, '{"id":"rejected-id","status":"Invalid"}', '')
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            with patch.object(package_release.subprocess, 'run', return_value=result), \
                    patch.object(package_release, 'run', return_value='{"issues":["bad signature"]}'):
                with self.assertRaisesRegex(RuntimeError, 'not accepted: Invalid'):
                    package_release.notarize(Path('release.dmg'), [], logs)
            self.assertEqual(json.loads((logs / 'release.dmg.notary.json').read_text())['id'], 'rejected-id')
            self.assertTrue((logs / 'release.dmg.notary-log.json').exists())

    def test_timeout_does_not_count_as_success_or_lose_submission_id(self):
        result = subprocess.CompletedProcess([], 69, '{"id":"pending-id","status":"In Progress"}', '')
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(package_release.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(RuntimeError, 'not accepted: In Progress'):
                    package_release.notarize(Path('release.dmg'), [], Path(directory))
            self.assertIn('pending-id', (Path(directory) / 'release.dmg.notary.json').read_text())

    def test_existing_artifact_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'release.dmg'
            output.write_bytes(b'original release')
            with patch.dict(os.environ, {'MACOS_SIGNING_IDENTITY': 'identity', 'APPLE_TEAM_ID': 'team'}):
                with self.assertRaisesRegex(RuntimeError, 'Refusing to overwrite'):
                    package_release.package(argparse.Namespace(output=output))
            self.assertEqual(output.read_bytes(), b'original release')

    def test_missing_credentials_does_not_produce_an_unsigned_artifact(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(RuntimeError, 'MACOS_SIGNING_IDENTITY'):
                package_release.package(argparse.Namespace())


if __name__ == '__main__':
    unittest.main()
