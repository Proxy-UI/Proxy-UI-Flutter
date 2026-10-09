#!/usr/bin/env python3
"""Package the complete Windows bundle with one CipherRelay directory."""
import argparse
from pathlib import Path
import zipfile

from release_artifact_name import artifact_name

REQUIRED = ('CipherRelay.exe', 'http_proxy.dll', 'wintun.dll', 'flutter_windows.dll', 'data')


def package(bundle, output_directory):
    for name in REQUIRED:
        if not (bundle / name).exists():
            raise ValueError(f'Windows bundle is missing {name}')
    output_directory.mkdir(parents=True, exist_ok=True)
    output = output_directory / artifact_name('windows', 'x64', 'zip')
    with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(bundle.rglob('*')):
            if file.is_file():
                archive.write(file, Path('CipherRelay') / file.relative_to(bundle))
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('output_directory', type=Path)
    args = parser.parse_args()
    print(package(args.bundle, args.output_directory))
