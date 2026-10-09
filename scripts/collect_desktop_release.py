#!/usr/bin/env python3
"""Validate the desktop release matrix before copying assets for publication."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import zipfile

from release_artifact_name import artifact_name


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def collect(artifacts, output, tag, native_version, source_commit):
    pubspec = Path(__file__).resolve().parents[1] / 'pubspec.yaml'
    version = re.search(r'(?m)^version:\s*(\S+)\+(\d+)\s*$', pubspec.read_text())
    if version is None or tag != f'v{version[1]}':
        raise ValueError('Release tag must match pubspec.yaml')
    expected = {
        artifact_name('macos', 'universal', 'dmg'),
        artifact_name('windows', 'x64', 'zip'),
        artifact_name('windows', 'x64-setup', 'exe'),
        artifact_name('linux', 'x64', 'tar.gz'),
    }
    files = [p for p in artifacts.rglob('*') if p.is_file() and
             (p.suffix in ('.dmg', '.zip', '.exe', '.apk', '.ipa') or p.name.endswith('.tar.gz'))]
    if len(files) != len(expected) or {p.name for p in files} != expected:
        raise ValueError(f'Desktop matrix mismatch: expected {sorted(expected)}, found {sorted(p.name for p in files)}')
    by_name = {p.name: p for p in files}
    with zipfile.ZipFile(by_name[artifact_name('windows', 'x64', 'zip')]) as archive:
        names = set(archive.namelist())
        required = {f'CipherRelay/{name}' for name in ('CipherRelay.exe', 'http_proxy.dll', 'wintun.dll', 'flutter_windows.dll')}
        if not required <= names or not any(name.startswith('CipherRelay/data/') for name in names):
            raise ValueError('Windows portable archive is incomplete')
        if any(not name.startswith('CipherRelay/') for name in names):
            raise ValueError('Windows portable archive must contain one CipherRelay directory')
    with tarfile.open(by_name[artifact_name('linux', 'x64', 'tar.gz')]) as archive:
        names = set(archive.getnames())
        if not {'CipherRelay/CipherRelay', 'CipherRelay/lib/libhttp_proxy.so'} <= names:
            raise ValueError('Linux archive is incomplete')
        if not any(name.startswith('CipherRelay/data/') for name in names):
            raise ValueError('Linux archive is missing Flutter data')
    native = json.loads((artifacts / 'native-libs/native-release-manifest.json').read_text())
    if native['version'] != native_version or not re.fullmatch(r'[0-9a-f]{40}', native['source_commit']):
        raise ValueError('Native release provenance does not match requested version')
    report_files = list((artifacts / 'macos-verification').rglob('release.json'))
    if len(report_files) != 1:
        raise ValueError('Expected one final macOS verification report')
    mac = json.loads(report_files[0].read_text())
    dmg = by_name[artifact_name('macos', 'universal', 'dmg')]
    if (mac['version'] != version[1] or str(mac['build']) != version[2]
            or mac['architectures'] != ['arm64', 'x86_64']
            or not mac.get('mounted_app_verified') or mac['sha256'] != digest(dmg)
            or mac['team_id'] != '5T7QB722FM' or mac['size'] != dmg.stat().st_size):
        raise ValueError('macOS report does not verify this release image')
    output.mkdir(parents=True, exist_ok=False)
    manifest = {'version': version[1], 'build': version[2], 'source_commit': source_commit,
                'native_version': native_version, 'native_source_commit': native['source_commit'],
                'macos_verification': mac, 'assets': []}
    for file in sorted(files):
        shutil.copy2(file, output / file.name)
        manifest['assets'].append({'name': file.name, 'size': file.stat().st_size, 'sha256': digest(file)})
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    (output / 'SHA256SUMS').write_text(''.join(f"{a['sha256']}  {a['name']}\n" for a in manifest['assets']))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('tag')
    parser.add_argument('native_version')
    parser.add_argument('source_commit')
    args = parser.parse_args()
    collect(args.artifacts, args.output, args.tag, args.native_version, args.source_commit)
    print('Verified all four desktop release artifacts and macOS notarization report')
