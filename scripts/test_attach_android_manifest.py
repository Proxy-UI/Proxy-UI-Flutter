import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from attach_android_manifest import ABI_OFFSETS, CERTIFICATE, apk_metadata, attach


class AndroidManifestTest(unittest.TestCase):
    def test_effective_split_version_and_stable_certificate_are_required(self):
        badging = "package: name='com.proxyui.proxy_ui' versionCode='2071' versionName='2.0.6'\nnative-code: 'arm64-v8a'\n"
        signing = f'Signer #1 certificate SHA-256 digest: {CERTIFICATE}\n'
        self.assertEqual(apk_metadata(badging, signing, '2.0.6', 71, 'arm64-v8a')['version_code'], 2071)
        for changed in (badging.replace('2071', '2070'), badging.replace('com.proxyui.proxy_ui', 'com.other.app'),
                        badging.replace("'arm64-v8a'", "'arm64-v8a' 'x86_64'")):
            with self.assertRaises(ValueError):
                apk_metadata(changed, signing, '2.0.6', 71, 'arm64-v8a')
        with self.assertRaises(ValueError):
            apk_metadata(badging, signing.replace(CERTIFICATE, '0' * 64), '2.0.6', 71, 'arm64-v8a')

    def test_android_hotfix_preserves_desktop_identity_and_verifies_old_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            def asset(name, **metadata):
                (directory / name).write_bytes(name.encode())
                return dict(name=name, size=len(name),
                            sha256=hashlib.sha256(name.encode()).hexdigest(), **metadata)
            desktop = asset('desktop.zip', platform='windows')
            old = [asset(f'cipherrelay-v2.0.8-76-android-{abi}.apk',
                         platform='android', abis=[abi], version_code=offset + 76)
                   for abi, offset in ABI_OFFSETS.items()]
            original = dict(version='2.0.8', build=76, source_commit='a' * 40,
                            assets=[desktop, *old])
            path = directory / 'release-manifest.json'
            path.write_text(json.dumps(original))
            for abi in ABI_OFFSETS:
                asset(f'cipherrelay-v2.0.8-77-android-{abi}.apk')

            def inspect(command, **kwargs):
                abi = next(abi for abi in ABI_OFFSETS if str(command[-1]).endswith(f'-{abi}.apk'))
                if command[1] == 'dump':
                    return (f"package: name='com.proxyui.proxy_ui' versionCode='{ABI_OFFSETS[abi]+77}' "
                            f"versionName='2.0.8'\nnative-code: '{abi}'\n")
                return f'Signer #1 certificate SHA-256 digest: {CERTIFICATE}\n'

            with patch('attach_android_manifest.subprocess.check_output', side_effect=inspect):
                attach(directory, Path('tools'), 'a' * 40, android_build=77,
                       android_source_commit='b' * 40, android_native_source_commit='c' * 40)
            updated = json.loads(path.read_text())
            self.assertEqual(updated['build'], 76)
            self.assertEqual(updated['source_commit'], 'a' * 40)
            self.assertEqual(updated['android_build'], 77)
            self.assertEqual(updated['android_source_commit'], 'b' * 40)
            self.assertIn(desktop, updated['assets'])
            self.assertEqual(len(updated['assets']), 4)
            with self.assertRaises(ValueError):
                attach(directory, Path('tools'), 'a' * 40, android_build=77,
                       android_source_commit='b' * 40, android_native_source_commit='c' * 40)
            path.write_text(json.dumps(original))
            (directory / 'desktop.zip').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                attach(directory, Path('tools'), 'a' * 40, android_build=77,
                       android_source_commit='b' * 40, android_native_source_commit='c' * 40)
