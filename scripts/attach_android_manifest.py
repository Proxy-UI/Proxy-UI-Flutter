#!/usr/bin/env python3
"""Add already locally built APKs to a verified desktop update manifest.

This tool does not build or sign APKs. Verify the existing manifest signature
before calling it, then sign the resulting manifest with the update key.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

CERTIFICATE = '5ac9aa7c2a99b410864e7e88b4ec9a28771ddadf69c620a9b18b8dd66ac8305c'
ABI_OFFSETS = {'armeabi-v7a': 1000, 'arm64-v8a': 2000, 'x86_64': 4000}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def apk_metadata(badging, signing, version, build, abi):
    package = re.search(r"^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging, re.M)
    native = re.search(r'^native-code: (.+)$', badging, re.M)
    certs = re.findall(r'^Signer #\d+ certificate SHA-256 digest: ([a-f0-9]+)$', signing, re.M)
    code = ABI_OFFSETS[abi] + build
    if (package is None or package.groups() != ('com.proxyui.proxy_ui', str(code), version)
            or native is None or native[1].strip() != f"'{abi}'"
            or certs != [CERTIFICATE]):
        raise ValueError(f'APK package, version, ABI or signing certificate differs: {abi}')
    return {'platform': 'android', 'abis': [abi], 'version_code': code,
            'certificate_sha256': CERTIFICATE}


def attach(directory, tools, source_commit):
    manifest_path = directory / 'release-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest['source_commit'] != source_commit:
        raise ValueError('Release manifest does not belong to this source commit')
    version, build = manifest['version'], int(manifest['build'])
    # Preserve every existing desktop entry only after verifying its bytes.
    for asset in manifest['assets']:
        if not re.fullmatch(r'[A-Za-z0-9._-]+', asset['name']):
            raise ValueError('Asset must be a plain filename')
        path = directory / asset['name']
        if path.stat().st_size != asset['size'] or digest(path) != asset['sha256']:
            raise ValueError(f'Existing asset checksum differs: {path.name}')
    expected = {f'cipherrelay-v{version}-{build}-android-{abi}.apk': abi for abi in ABI_OFFSETS}
    if {path.name for path in directory.glob('*.apk')} != set(expected):
        raise ValueError('Expected exactly the three local split APKs for this release')
    entries = [asset for asset in manifest['assets'] if asset.get('platform') != 'android']
    for name, abi in sorted(expected.items()):
        path = directory / name
        badging = subprocess.check_output([str(tools / 'aapt'), 'dump', 'badging', str(path)], text=True)
        signing = subprocess.check_output([str(tools / 'apksigner'), 'verify', '--print-certs', str(path)], text=True)
        metadata = apk_metadata(badging, signing, version, build, abi)
        entries.append({'name': name, 'size': path.stat().st_size, 'sha256': digest(path), **metadata})
    manifest['assets'] = sorted(entries, key=lambda asset: asset['name'])
    manifest['android_build_environment'] = 'maintainer-local'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    (directory / 'SHA256SUMS').write_text(''.join(f"{a['sha256']}  {a['name']}\n" for a in manifest['assets']))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('build_tools', type=Path)
    parser.add_argument('source_commit')
    args = parser.parse_args()
    attach(args.directory, args.build_tools, args.source_commit)
