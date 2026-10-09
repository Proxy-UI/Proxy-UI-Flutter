# Mac App Store development

The `appstore` scheme builds **CipherRelay.app** (macOS 13+) with an embedded
Packet Tunnel extension. It has its own bundle ID and sandbox container. The
main switch controls the system VPN; helper-based TUN, process bypass and
system-proxy modification are unavailable in this target. LAN configuration
sharing and external GeoIP queries/database downloads are also disabled.

Version 1.2.16 (42) was submitted to App Review on 14 September 2026 and entered
Waiting for Review. It has not been approved. See [submitted listing and review
instructions](app-store-listing.md).

Build from the Rust repository with this Flutter repository at `ui/flutter`:

```bash
python3 scripts/macos/build-app-store.py --architectures universal --unsigned
# After configuring development signing in Xcode:
python3 scripts/macos/build-app-store.py --team YOUR_TEAM_ID --architectures arm64
python3 scripts/macos/build-app-store.py --team YOUR_TEAM_ID --archive
```

The Rust feature `proxy-ffi/mac-app-store`, Swift condition `MAC_APP_STORE`, and
Dart define `MAC_APP_STORE=true` must all agree. Do not reuse the desktop native
artifacts. The script stages feature-specific artifacts under
`native/macos-app-store/`, runs CocoaPods and verifies the final bundle.

The containing app and extension use these App IDs with Network Extensions:

- `com.proxyui.proxyUi.store`
- `com.proxyui.proxyUi.store.PacketTunnel`

Both need valid development profiles and the shared Keychain entitlement
`$(AppIdentifierPrefix)com.proxyui.proxyUi.store.shared`. The VPN preference
contains only a Keychain persistent reference; the actual configuration and
credentials stay in the Data Protection Keychain. Each process keeps its own
sandboxed cache. The extension reports connection state to the app; its detailed
logs currently use macOS unified logging, not the app's log page.

Output: `build/macos-app-store/Build/Products/Release-appstore/CipherRelay.app`.
An unsigned build validates compilation and packaging only: it cannot connect
a system VPN and must not be distributed as an installable release. A signed
archive still needs Xcode validation, runtime testing and App Review.

On first use, the Store edition shows a privacy disclosure before constructing
proxy services. **Explore demo** opens an isolated, in-memory demo without VPN,
network or saved-setting changes. The main toolbar also provides demo and
privacy buttons. The [public policy](privacy-policy.md) describes actual traffic
and local storage separately from the offline demo.

Run the normal FVM tests and the store-specific suite:

```bash
fvm flutter analyze --no-fatal-infos
fvm flutter test
fvm flutter test test/macos_vpn_service_test.dart test/store_demo_test.dart test/store_privacy_test.dart --dart-define=MAC_APP_STORE=true
```

The full implementation and runtime acceptance procedure are documented in
`docs/mac-app-store.md` in the Rust repository. Apple requires an organization
membership to publish VPN apps under [App Review guideline 5.4](https://developer.apple.com/app-store/review/guidelines/#vpn-apps).
