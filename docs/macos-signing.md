# macOS releases outside the App Store

The desktop release workflow signs the app, its Flutter frameworks, proxy dylib,
and privileged TUN helper with a **Developer ID Application** certificate. It
enables the hardened runtime and secure timestamp, notarizes and staples both
the app and DMG, and checks Gatekeeper before uploading the DMG. The disk image
contains the app and an Applications shortcut for drag-and-drop installation.
macOS may still ask the normal first-open confirmation for an Internet download.

Signing credentials are required even for a build with `create_release: false`.
Missing credentials, incomplete universal binaries, nonportable library paths,
or rejected notarization stop the macOS job and prevent release publication.
The package's minimum macOS version reflects the highest deployment target of
its bundled binaries, including Flutter plugins.

## Repository configuration

Configure these in **Proxy-UI/Proxy-UI-Flutter → Settings → Secrets and variables
→ Actions**. Never commit signing keys or paste their contents into logs.

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded PKCS#12 containing the Developer ID Application certificate, private key and intermediate certificate |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | PKCS#12 export password |
| Secret | `APPLE_NOTARY_PRIVATE_KEY` | Complete App Store Connect team API private key (`.p8`) for notarization |
| Variable | `MACOS_SIGNING_IDENTITY` | Full Developer ID Application identity or certificate SHA-1 |
| Variable | `APPLE_TEAM_ID` | Apple Developer team ID |
| Variable | `APPLE_NOTARY_KEY_ID` | App Store Connect team API key ID |
| Variable | `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |

Use an App Store Connect team API key with the Developer role; a certificate's
private key and an API key are different credentials. Restrict repository write
access because users who can change privileged workflows can use its secrets.
When rotating credentials, replace the corresponding secret/variable and run
the workflow with release creation disabled before the next release.

Each job imports the certificate into a temporary keychain with access for
`codesign`, stores the notarization key in that keychain, then removes the loose
credential files. The keychain is deleted on completion; an `always()` cleanup
also covers failed/cancelled jobs. Only the DMG and verification logs are uploaded.

## Local signing or re-signing an existing release

Keep the original DMG as a backup. Mount it read-only, copy `CipherRelay.app` out
using `ditto`, and unmount it. Use the same script as CI, with an existing local
Developer ID identity and a `notarytool` keychain profile:

```sh
export MACOS_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export APPLE_TEAM_ID='TEAMID'
export APPLE_NOTARY_PROFILE='proxy-ui-notary'
# Optional when using dedicated, unlocked keychains:
# export MACOS_SIGNING_KEYCHAIN='/path/to/signing.keychain-db'
# export APPLE_NOTARY_KEYCHAIN='/path/to/notary.keychain-db'
python3 scripts/macos/package_release.py \
  --app /path/to/CipherRelay.app \
  --output /path/to/new/cipherrelay-macos.dmg
```

The input app is copied before signing. An existing output file is never
overwritten. The verification directory records Apple submission IDs, bundle
version/build, architectures, minimum OS, team ID and final SHA-256. Publish only
after the script succeeds. Re-signing a release keeps its application version
and build; it changes the package checksum and signatures.

See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [GitHub's certificate storage guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
