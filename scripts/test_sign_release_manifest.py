from pathlib import Path
import subprocess
import tempfile
import unittest

from sign_release_manifest import sign, verify


class SignReleaseManifestTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.key = root / 'key.pem'
        self.public = root / 'key.pub.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'ed25519', '-out', str(self.key)], check=True)
        subprocess.run(['openssl', 'pkey', '-in', str(self.key), '-pubout', '-out', str(self.public)], check=True)
        self.manifest = root / 'release-manifest.json'
        self.manifest.write_text('{"version": "2.0.6", "build": "65", "assets": []}\n')

    def test_signature_covers_the_exact_manifest(self):
        signature = sign(self.manifest, self.key)
        self.assertEqual(signature.name, 'release-manifest.json.sig')
        verify(self.manifest, self.public)
        self.manifest.write_text(self.manifest.read_text().replace('65', '66'))
        with self.assertRaises(subprocess.CalledProcessError):
            verify(self.manifest, self.public)


if __name__ == '__main__':
    unittest.main()
