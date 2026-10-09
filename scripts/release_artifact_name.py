#!/usr/bin/env python3
"""Print the versioned delivery filename; Flutter's intermediate names stay internal."""

import argparse
from pathlib import Path
import re


def artifact_name(platform, architecture, extension):
    pubspec = Path(__file__).resolve().parents[1] / "pubspec.yaml"
    version = re.search(
        r"(?m)^version:\s*(\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?)\+(\d+)\s*$",
        pubspec.read_text(),
    )
    if version is None:
        raise ValueError("pubspec.yaml must declare a version and build number")
    return f"cipherrelay-v{version[1]}-{version[2]}-{platform}-{architecture}.{extension}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=["android", "ios", "linux", "macos", "windows"])
    parser.add_argument("architecture", choices=["universal", "arm64", "x64", "arm64-v8a", "armeabi-v7a", "x86_64"])
    parser.add_argument("extension", choices=["apk", "ipa", "dmg", "zip", "tar.gz"])
    args = parser.parse_args()
    print(artifact_name(args.platform, args.architecture, args.extension))
