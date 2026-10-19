import unittest

from attach_android_manifest import CERTIFICATE, apk_metadata


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
