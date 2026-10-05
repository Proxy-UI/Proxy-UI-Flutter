# CipherRelay

A cross-platform Flutter GUI for encrypted proxy client.

## macOS editions

CipherRelay (formerly Proxy UI) keeps a direct-download edition and a separate
Mac App Store target. The direct edition produces `CipherRelay.app` and keeps
its privileged helper, system proxy, LAN access and process bypass. The
`appstore` scheme produces sandboxed `CipherRelay Store.app` with its own bundle
ID and Packet Tunnel extension. See [the store build guide](docs/macos-app-store.md).
Version 1.2.16 (42) was submitted on 14 September 2026; it has not passed App Review.

App IDs, Dart package imports, Windows/Linux executable names and persisted
settings keys remain unchanged for upgrade compatibility. Repository URLs also
remain unchanged. Replace the old direct-download app with `CipherRelay.app`
when installing an update; the Store app has a separate settings container.

## Interface language

The translate button in the global title bar selects **System default**,
**简体中文**, or **English**. The selection is saved across launches and updates
navigation, proxy controls, nodes, subscriptions, logs, settings, dialogs, and
tray menus without restarting the proxy or TUN. The same control in the TUN
guide changes the application language. Original native logs, process names,
paths, and executable commands remain intact.

Translations use Flutter `gen-l10n` with `lib/l10n/app_en.arb` and
`lib/l10n/app_zh.arb`. Add matching entries to both files, then run
`fvm flutter gen-l10n` from this directory. Generated localization sources are
ignored; normal FVM builds regenerate them.

## Features

- **Low-latency encrypted transport v3 (1.2.19+45)**: Requires native 0.4.33 on the client and every relay/server. The switch encrypts TCP, UDP and control without an extra handshake round trip. Fresh sender salts separate connections/directions; whole-connection replay protection is not promised. Default off retains legacy compatibility. Failures never silently downgrade. Mac App Store Packet Tunnel remains legacy-only.
- **Connection recovery (1.2.17+43)**: Paired with native 0.4.31, Windows refreshes physical egress for new sessions after network changes. Native handle operations are serialized, cleanup runs off the UI thread, logs are bounded, and connection status is checked independently of logs. See the parent repository's `docs/network-resilience.md` for limits and validation.
- **Proxy Control**: One-tap start/stop proxy with visual status indicator
- **Configuration**: Server host, port, session key, and local port settings
- **Optional LAN Access**: Expose the local proxy to trusted LAN devices with a copyable Wi-Fi HTTP proxy link
- **Auto Proxy**: Geo-based routing (CN direct, others proxy)
- **SOCKS5 UDP**: Toggle RFC 1928 UDP relay on the same local proxy port
- **Windows TUN**: Capture device TCP/UDP with runtime process exclusions
- **Subscriptions**: Export UDP-aware Clash and Shadowrocket configurations
- **Real-time Logs**: Colored log viewer with level filtering (TRACE/DEBUG/INFO/WARN/ERROR)
- **Desktop Log Files**: Hourly log files with three-day retention and one-click folder access
- **Theme Switching**: 4 color themes (Cyberpunk, Sunset, Ocean, Forest)
- **Dark/Light Mode**: Toggle between dark and light appearance
- **Responsive Layout**: Adapts to phone, tablet, and desktop screens
- **Material 3 Design**: Modern UI with smooth animations

## Supported Platforms

| Platform | Status |
|----------|--------|
| Android | ✅ |
| iOS | ✅ |
| Linux | ✅ |
| macOS | ✅ |
| Windows | ✅ |
| Web | ⚠️ (UI only, no FFI) |

## Desktop window and exit behavior

Closing the window (Windows **×** / Alt-F4, or the macOS red close button)
hides it to the tray while the proxy and TUN continue running. Click the tray
icon to reopen it; macOS also supports reopening from the Dock.

Use the tray menu's **Quit**, or **Cmd-Q** / **Dock > Quit** on macOS, to stop
the services and exit. These quit paths wait for TUN routes and DNS to be
restored before terminating the process.

## Build

### Prerequisites

- [FVM](https://fvm.app/) 4.x
- Visual Studio 2022 with the Desktop development with C++ workload (Windows)
- Rust toolchain from the parent `proxy-everything` repository

Flutter is pinned to 3.44.9 in `.fvmrc`. Do not invoke a globally installed
`flutter` or `dart`; use `fvm flutter` and `fvm dart` so local and CI builds use
the same SDK.

### Local Development

```bash
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

#### macOS

Public DMGs are Developer ID signed and Apple notarized. Maintainers must
configure [macOS signing credentials](docs/macos-signing.md) before running the
release workflow. The packaging script verifies every bundled binary and
Gatekeeper acceptance before uploading the DMG.

Stage the native artifacts from the parent repository:

```bash
# in the parent proxy-everything repository
bash scripts/macos/stage-ui-native.sh --configuration Release
```

That builds and stages two files into `native/macos/`, both of which the app
needs: `libhttp_proxy.dylib` and `http-proxy-tun-helper`. The helper exists
because macOS requires root to create a utun device and offers no way to elevate
a running app, so TUN mode runs in a separate process started through an
administrator prompt. Without it the TUN switch can only report a missing helper.

The equivalent by hand, if you would rather not use the script:

```bash
# in the parent proxy-everything repository.
# Two commands: `--bin` filters targets across the whole package selection, so
# combining these would skip the proxy-ffi library and leave a stale dylib.
cargo build -p proxy-ffi --release
cargo build -p proxy-client --bin http-proxy-tun-helper --release

# in this repository
mkdir -p native/macos
cp ../proxy-everything/target/release/libhttp_proxy.dylib native/macos/
cp ../proxy-everything/target/release/http-proxy-tun-helper native/macos/
install_name_tool -id "@rpath/libhttp_proxy.dylib" native/macos/libhttp_proxy.dylib
codesign --force --sign - native/macos/libhttp_proxy.dylib
codesign --force --sign - native/macos/http-proxy-tun-helper
```

The `install_name_tool` step is required: without an `@rpath` install name the
bundled app looks for the dylib at its absolute build path and fails to load it.

Then keep CocoaPods for plugin integration and build:

```bash
fvm flutter build macos --release
```

CocoaPods is selected in `pubspec.yaml` for the pinned Flutter SDK. The tracked
`macos/Podfile` defines both `Runner` and `RunnerStore`, so plugin integration is
reproducible without changing the global Flutter configuration.

For the separate sandboxed VPN target, see [Mac App Store development](docs/macos-app-store.md).

The native files are only embedded by the Xcode phase, so re-stage and re-sign
them after each build, matching what CI does:

```bash
APP=build/macos/Build/Products/Release/CipherRelay.app
cp native/macos/libhttp_proxy.dylib "$APP/Contents/Frameworks/"
cp native/macos/http-proxy-tun-helper "$APP/Contents/MacOS/"
codesign --force --sign - "$APP/Contents/Frameworks/libhttp_proxy.dylib"
codesign --force --sign - "$APP/Contents/MacOS/http-proxy-tun-helper"
codesign --force --deep --sign - "$APP"
```

The helper lives in `Contents/MacOS/` rather than `Contents/Frameworks/` because
native code locates it relative to its own executable path.

##### TUN mode on macOS

Start the local proxy first, then use the TUN switch. Enabling it asks for an
administrator password once per session; the app itself stays unprivileged and
keeps serving the local SOCKS5 listener while the authorized helper owns the
utun device and the system routes. Turning the switch off restores the previous
routes and DNS settings, and so does quitting or crashing the app — the helper
notices its control socket closing and cleans up on its own.

System proxy mode configures the primary network service (for example Wi-Fi),
even while a VPN captures Internet routes. HTTP, HTTPS, and SOCKS settings are
restored independently on that same service when the proxy stops. A failure to
apply the requested system proxy is reported as a startup error.

Before requesting administrator access, TUN checks whether another tunnel
already owns Internet routes. A conflict leaves routes, DNS, and the local proxy
unchanged and is reported in the UI. Closing another VPN's window may leave its
background service running. The TUN helper sends its forwarding diagnostics to
the UI Logs tab, and direct relays retain the physical DNS servers captured
before TUN setup changes DNS.

On macOS, the question-mark button next to TUN opens a read-only diagnostic
guide; TUN setup failures open the same guide automatically. It checks the
selected Internet/fake-IP routes, maps each utun socket to its current owning
PID, and displays the executable path without collecting process arguments.
Interface names are reusable, so an active CipherRelay helper is identified as
this app rather than attributed to a previously running VPN.

The guide provides localized step-by-step instructions, copyable route checks,
and application reopen commands. When the current owner is an identified
third-party application, it offers a temporary SIGTERM command matched by its
escaped full executable path rather than a stale PID. The command requests all
running instances of that executable to exit and can interrupt their connections.
A specific client hint appears only after its executable is identified. All commands are copied for manual use; diagnostics never
stop processes or modify routes. Recheck refreshes the evidence and enables
retry only when both route lookups succeed without selecting a utun interface.
Unknown owners and system processes do not receive termination commands.

The TUN bypass picker (the shield button next to the switch) selects applications
to keep out of the tunnel, and works while a session is running: changes are sent
to the helper, which reroutes new connections and closes established ones whose
decision changed so the application reconnects on the new path. The app's own
executable is always bypassed and cannot be deselected.

The list covers processes owned by the current user. Unlike Windows, there are no
executable icons and no dormant installed applications, because macOS keeps icons
inside `.app` bundles and only running processes can be enumerated unprivileged.

#### Windows

The desktop app requires the Rust `http_proxy` native library. Windows TUN mode
also requires `wintun.dll`; the parent build scripts stage both DLLs. When developing
from the parent repository on Windows, the recommended command builds and
stages the DLL before starting Flutter. Run it from the parent repository root:

```powershell
.\scripts\windows\run-ui.ps1
```

Build the complete Rust workspace and Windows UI together with:

```powershell
.\scripts\windows\build.ps1 -Configuration Release
```

The Windows executable normally runs without administrator privileges. Start
the local proxy first, then use the top-level TUN switch; only that action
requests UAC and relaunches the same GUI elevated without a terminal window.
The switch reports enabled only after Wintun and route setup are ready. The TUN
process picker is available before and during a connection. Native code protects
the resolved remote proxy routes and always excludes the UI executable itself
to prevent a capture loop. The picker displays Windows executable icons and
expandable launcher/child-process trees; choosing a parent application bypasses
all descendants without persisting volatile child PIDs.

### Trigger Release Build

Use GitHub Actions workflow dispatch:

```bash
gh workflow run build.yaml \
  -f lib_version=<version> \
  -f create_release=true \
  -f release_tag=v1.0.0
```

Parameters:
- `lib_version`: Native library version
- `create_release`: Whether to create GitHub release (default: true)
- `release_tag`: Release tag name (e.g., v1.0.0)

## CI/CD

- **CI** (`ci.yml`): Runs on every push/PR to `main`/`dev` - checks code analysis, formatting, and builds
- **Release** (`build.yaml`): Manual trigger - builds all platforms and creates GitHub release
