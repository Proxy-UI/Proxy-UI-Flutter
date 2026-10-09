import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from collect_desktop_release import collect, digest
from package_windows_portable import package
from release_artifact_name import artifact_name
from stage_windows_installer import stage


class DesktopReleaseTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.artifacts = self.root / 'artifacts'
        self.artifacts.mkdir()
        bundle = self.root / 'bundle'
        (bundle / 'data').mkdir(parents=True)
        for name in ('CipherRelay.exe', 'http_proxy.dll', 'wintun.dll', 'flutter_windows.dll', 'data/icudtl.dat'):
            (bundle / name).write_bytes(b'fixture')
        self.zip = package(bundle, self.artifacts / 'windows-packages')
        self.exe = self.artifacts / artifact_name('windows', 'x64-setup', 'exe')
        self.exe.write_bytes(b'MZfixture')
        linux = self.artifacts / artifact_name('linux', 'x64', 'tar.gz')
        with tarfile.open(linux, 'w:gz') as archive:
            for name in ('CipherRelay/CipherRelay', 'CipherRelay/lib/libhttp_proxy.so', 'CipherRelay/data/icudtl.dat'):
                info = tarfile.TarInfo(name)
                info.size = 7
                archive.addfile(info, io.BytesIO(b'fixture'))
        self.dmg = self.artifacts / artifact_name('macos', 'universal', 'dmg')
        self.dmg.write_bytes(b'fixture')
        # Derive the fixture's version from the same public filename contract.
        version, build = self.dmg.name.removeprefix('cipherrelay-v').split('-')[:2]
        self.tag = 'v' + version
        (self.artifacts / 'macos-verification').mkdir()
        (self.artifacts / 'macos-verification/release.json').write_text(json.dumps({
            'version': version, 'build': build, 'architectures': ['arm64', 'x86_64'],
            'team_id': '5T7QB722FM', 'mounted_app_verified': True,
            'sha256': digest(self.dmg), 'size': self.dmg.stat().st_size,
        }))
        (self.artifacts / 'native-libs').mkdir()
        (self.artifacts / 'native-libs/native-release-manifest.json').write_text(json.dumps({
            'version': '0.4.37', 'source_commit': 'a' * 40,
        }))

    def run_collect(self):
        return collect(self.artifacts, self.root / 'release', self.tag, '0.4.37', 'b' * 40)

    def test_complete_desktop_matrix_has_hashes_and_provenance(self):
        manifest = self.run_collect()
        self.assertEqual(len(manifest['assets']), 4)
        self.assertEqual(manifest['native_source_commit'], 'a' * 40)
        self.assertEqual(len((self.root / 'release/SHA256SUMS').read_text().splitlines()), 4)

    def test_modified_dmg_cannot_reuse_verification_report(self):
        self.dmg.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'macOS report'):
            self.run_collect()

    def test_missing_installer_prevents_publication(self):
        self.exe.unlink()
        with self.assertRaisesRegex(ValueError, 'matrix mismatch'):
            self.run_collect()

    def test_mobile_or_old_package_cannot_join_release(self):
        (self.artifacts / 'old.apk').write_bytes(b'old')
        with self.assertRaisesRegex(ValueError, 'matrix mismatch'):
            self.run_collect()

    def test_wrong_tag_cannot_label_old_version(self):
        with self.assertRaisesRegex(ValueError, 'tag must match'):
            collect(self.artifacts, self.root / 'release', 'v0.0.0', '0.4.37', 'b' * 40)

    def test_fastforge_installer_is_staged_without_changing_bytes(self):
        version, build = self.exe.name.removeprefix('cipherrelay-v').split('-')[:2]
        original = self.root / f'proxy_ui-{version}+{build}-windows-setup.exe'
        original.write_bytes(b'MZinstaller')
        delivered = stage(self.root, self.root / 'staged')
        self.assertEqual(delivered.name, self.exe.name)
        self.assertEqual(delivered.read_bytes(), original.read_bytes())

    def test_old_fastforge_installer_cannot_be_relabelled_as_new_version(self):
        (self.root / 'proxy_ui-0.0.0+1-windows-setup.exe').write_bytes(b'MZold')
        with self.assertRaisesRegex(ValueError, 'exactly one'):
            stage(self.root, self.root / 'staged')


if __name__ == '__main__':
    unittest.main()
