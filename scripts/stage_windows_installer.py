#!/usr/bin/env python3
"""Stage Fastforge's installer under the public CipherRelay release name."""
import argparse
from pathlib import Path
import re
import shutil

from release_artifact_name import artifact_name


def stage(distribution, output):
    pubspec = (Path(__file__).resolve().parents[1] / 'pubspec.yaml').read_text()
    version = re.search(r'(?m)^version:\s*(\S+)\s*$', pubspec)[1]
    package = re.search(r'(?m)^name:\s*(\S+)\s*$', pubspec)[1]
    # Fastforge 0.6.x uses the Dart package name for its intermediate output.
    candidates = list(distribution.rglob(f'{package}-{version}-windows-setup.exe'))
    if len(candidates) != 1:
        raise ValueError('Expected exactly one Fastforge installer for the current version')
    with candidates[0].open('rb') as file:
        if file.read(2) != b'MZ':
            raise ValueError('Windows installer is not a PE executable')
    output.mkdir(parents=True, exist_ok=True)
    destination = output / artifact_name('windows', 'x64-setup', 'exe')
    if destination.exists():
        raise FileExistsError(destination)
    shutil.copy2(candidates[0], destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('distribution', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(stage(args.distribution, args.output))
