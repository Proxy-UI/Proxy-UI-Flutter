# Proxy UI

A cross-platform Flutter GUI for encrypted proxy client.

## Features

- **Proxy Control**: One-tap start/stop proxy with visual status indicator
- **Configuration**: Server host, port, session key, and local port settings
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

## Build

### Prerequisites

- [FVM](https://fvm.app/) 4.x
- Visual Studio 2022 with the Desktop development with C++ workload (Windows)
- Rust toolchain from the parent `proxy-everything` repository

Flutter is pinned to 3.38.6 in `.fvmrc`. Do not invoke a globally installed
`flutter` or `dart`; use `fvm flutter` and `fvm dart` so local and CI builds use
the same SDK.

### Local Development

```bash
fvm install
fvm flutter pub get
fvm flutter run -d windows
```

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
