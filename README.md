# Proxy UI

A cross-platform Flutter GUI for encrypted proxy client.

## Features

- **Proxy Control**: One-tap start/stop proxy with visual status indicator
- **Configuration**: Server host, port, session key, and local port settings
- **Auto Proxy**: Geo-based routing (CN direct, others proxy)
- **Real-time Logs**: Colored log viewer with level filtering (TRACE/DEBUG/INFO/WARN/ERROR)
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

- **fvm** (manages the Flutter version) + Flutter **3.38.6** (pinned)
- Platform native libraries (downloaded from Releases, or built locally from the Rust sources)

> See **[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)** for full environment setup, native-library preparation and per-platform run instructions;
> see **[docs/CONVENTIONS.md](docs/CONVENTIONS.md)** for project structure / state management / FFI / coding conventions.

### Local Development

```bash
fvm install 3.38.6              # first time: install the pinned Flutter version
fvm use 3.38.6                  # pin the version for this directory (creates .fvmrc)
fvm flutter pub get
fvm flutter run -d windows      # or -d macos / -d linux / <device id>
```

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
