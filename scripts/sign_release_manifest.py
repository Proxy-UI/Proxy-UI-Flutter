#!/usr/bin/env python3
"""Sign a release manifest with the update key, or verify a signature.

The app downloads `release-manifest.json` and `release-manifest.json.sig`
from the latest release and refuses to install anything the signature does
not cover. Re-run this after changing the manifest, such as when attaching
locally signed Android packages, and upload the new `.sig` with it.

    sign:   sign_release_manifest.py release-manifest.json --key private.pem
    verify: sign_release_manifest.py release-manifest.json --verify public.pem

Requires OpenSSL 3 (`pkeyutl -rawin`). The signature file holds the base64
of the 64-byte Ed25519 signature over the manifest's exact bytes.
"""
import argparse
import base64
from pathlib import Path
import subprocess
import tempfile


def sign(manifest: Path, key: Path) -> Path:
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / 'signature'
        subprocess.run(
            ['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key),
             '-in', str(manifest), '-out', str(raw)],
            check=True,
        )
        signature = raw.read_bytes()
    if len(signature) != 64:
        raise ValueError('The key did not produce an Ed25519 signature')
    output = manifest.with_name(manifest.name + '.sig')
    output.write_text(base64.b64encode(signature).decode() + '\n')
    return output


def verify(manifest: Path, public_key: Path) -> None:
    signature = manifest.with_name(manifest.name + '.sig')
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / 'signature'
        raw.write_bytes(base64.b64decode(signature.read_text().strip()))
        subprocess.run(
            ['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin',
             '-inkey', str(public_key), '-in', str(manifest), '-sigfile', str(raw)],
            check=True,
        )


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('manifest', type=Path)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--key', type=Path, help='Ed25519 private key (PEM)')
    action.add_argument('--verify', type=Path, help='Ed25519 public key (PEM)')
    args = parser.parse_args()
    if args.key:
        print(sign(args.manifest, args.key))
    else:
        verify(args.manifest, args.verify)
