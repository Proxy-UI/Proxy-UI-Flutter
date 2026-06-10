# Development Guide

`proxy_ui` is the Flutter GUI for [proxy-everything](https://github.com/acking-you/proxy-everything). It talks to the Rust-based native proxy library (`http_proxy` / `libhttp_proxy`) over FFI. This guide explains how to get the app running locally, how to prepare the native library, and the release build flow.

> For code style and architecture, see [CONVENTIONS.md](./CONVENTIONS.md).

---

## 1. Requirements

| Tool | Version | Notes |
|------|---------|-------|
| **Flutter** | **3.38.6** (pinned) | Managed via fvm, see below |
| Dart SDK | ^3.9.0 | Installed together with Flutter |
| fvm | ≥ 3.x (4.x recommended) | Flutter version manager |
| Rust | see `rust-toolchain.toml` at the repo root | Only needed when building the native library locally |

Each platform also needs its own toolchain:

- **Windows**: Visual Studio 2022 (with "Desktop development with C++"), CMake
- **Android**: Android SDK / NDK, JDK 17
- **macOS / iOS**: Xcode + CocoaPods
- **Linux**: `clang`, `cmake`, `ninja-build`, `libgtk-3-dev`

---

## 2. Manage Flutter with fvm

This project is pinned to **Flutter 3.38.6** and managed with [fvm](https://fvm.app) so that everyone builds with the exact same SDK, regardless of any globally installed Flutter.

### 2.1 Install fvm

- **Option A (recommended, no admin):** download the standalone executable for your platform from the [GitHub Releases](https://github.com/leoafarias/fvm/releases), extract it, and add the directory to your `PATH`.
- **Option B:** `dart pub global activate fvm` (requires an existing Dart).
- **Option C (Windows, with Chocolatey):** `choco install fvm`.

Verify:

```bash
fvm --version
```

> **Cache location:** by default fvm installs each Flutter SDK under your home directory. To put them on a specific drive (e.g. one with more space), set the `FVM_CACHE_PATH` environment variable — for example this repo's local setup uses `D:\flutter_pro\fvm_cache`.

### 2.2 Install the required Flutter version

```bash
fvm install 3.38.6
```

> The first install performs a full clone of the Flutter git repository (a ~1GB+ mirror) and downloads the engine / Dart SDK artifacts, so it takes a while. This is a one-time cost — installing or switching versions later reuses the local mirror.

### 2.3 Pin the version for this project

From the `ui/flutter` directory:

```bash
fvm use 3.38.6
```

This generates `.fvmrc` (containing `{"flutter": "3.38.6"}`, **commit it**) and a `.fvm/` directory (a local symlink to the SDK, **gitignored**).

From then on, prefix every Flutter / Dart command with `fvm`:

```bash
fvm flutter pub get
fvm flutter run -d windows
fvm dart format lib/
```

### 2.4 IDE setup

- **VS Code:** in `.vscode/settings.json`
  ```json
  { "dart.flutterSdkPath": ".fvm/flutter_sdk" }
  ```
- **Android Studio / IntelliJ:** `Settings → Languages & Frameworks → Flutter`, set the Flutter SDK path to `<project>/.fvm/flutter_sdk`.

---

## 3. Network proxy (optional)

On restricted networks, installing Flutter via fvm, `pub get`, and Gradle/CocoaPods dependency fetches can be slow or fail. If you have a local HTTP proxy (this repo's setup uses `http://127.0.0.1:11111`), configure it as needed:

```bash
# git (fvm clones the Flutter mirror and submodules over git)
git config --global http.proxy  http://127.0.0.1:11111
git config --global https.proxy http://127.0.0.1:11111

# generic proxy for the current shell (inherited by curl / pub / fvm subprocesses)
export https_proxy=http://127.0.0.1:11111
export http_proxy=http://127.0.0.1:11111
```

> On Windows PowerShell use `$env:https_proxy="http://127.0.0.1:11111"`.
> Dart pub also honors the `https_proxy` / `http_proxy` environment variables, so no extra configuration is needed.

---

## 4. Native library (`http_proxy` / `libhttp_proxy`)

The UI loads the Rust native library over FFI. **The native library for your target platform must be in place before running or building**, otherwise the app fails at startup with `Failed to load dynamic library` or a symbol-lookup error.

### 4.1 Expected location

Native libraries for all platforms live under the project's top-level `native/` directory (referenced by each platform's build scripts):

| Platform | Directory | File | How it is wired in |
|----------|-----------|------|--------------------|
| Android | `native/android/{arm64-v8a,armeabi-v7a,x86_64}/` | `libhttp_proxy.so` | `android/app/build.gradle.kts` → `jniLibs.srcDirs("../../native/android")` |
| **Windows x64** | `native/windows/x64/` | `http_proxy.dll` | `windows/CMakeLists.txt` copies it into the bundle at install time |
| Windows arm64 | `native/windows/arm64/` | `http_proxy.dll` | same as above |
| Linux | `native/linux/{x64,arm64}/` | `libhttp_proxy.so` | `linux/CMakeLists.txt` copies it at install time |
| macOS | `native/macos/` | `libhttp_proxy.dylib` | xcconfig `-L .../native/macos -lhttp_proxy`, copied into `.app/Contents/Frameworks` at build time |
| iOS | `native/ios/` | `libhttp_proxy.a` (static) | xcconfig `-lhttp_proxy`, linked into the main executable |

> The Dart-side loading logic is in [`lib/src/ffi/proxy_ffi.dart`](../lib/src/ffi/proxy_ffi.dart) (`_loadLibrary()`).

### 4.2 Option A: download from Releases (what CI does)

The native libraries are published in the `acking-you/proxy-everything` Releases, named like `libhttp_proxy-<version>-<rust-target>.tar.gz`. CI (`.github/workflows/ci.yml`) uses `gh release download` to fetch and extract them into `native/`. Locally you can do the same, or download the package for your platform from the Releases page and place it according to the table above.

### 4.3 Option B: build from the Rust sources

From the **root of the proxy-everything repo** (two levels above `ui/flutter`):

```bash
# 1. Initialize submodules (first time)
git submodule update --init --recursive

# 2. Build the FFI library (release)
cargo build -p proxy-ffi --release
```

The output lands in `target/release/`; copy it to the matching `native/` directory for your platform:

| Platform | cargo output | copy to |
|----------|--------------|---------|
| Windows x64 | `target/release/http_proxy.dll` | `ui/flutter/native/windows/x64/` |
| Linux x64 | `target/release/libhttp_proxy.so` | `ui/flutter/native/linux/x64/` |
| macOS | `target/release/libhttp_proxy.dylib` | `ui/flutter/native/macos/` |
| iOS (cross-compile) | `target/aarch64-apple-ios/release/libhttp_proxy.a` | `ui/flutter/native/ios/` |
| Android (via `cargo-ndk`) | per-ABI `libhttp_proxy.so` | `ui/flutter/native/android/<abi>/` |

**Windows example:**

```bash
cargo build -p proxy-ffi --release
cp target/release/http_proxy.dll ui/flutter/native/windows/x64/
```

---

## 5. Run

Make sure you have: (1) run `fvm use 3.38.6`, and (2) the native library for your platform is in place.

```bash
cd ui/flutter
fvm flutter pub get
fvm flutter run -d windows      # or -d macos / -d linux / <android device id>
```

List available devices: `fvm flutter devices`.

> **Web** can only run the UI (no FFI, i.e. no actual proxy capability) — useful for previewing the interface.

---

## 6. Release builds

```bash
# per platform
fvm flutter build windows --release
fvm flutter build apk --release          # Android
fvm flutter build macos --release
fvm flutter build linux --release
fvm flutter build ipa --release          # iOS
```

The full cross-platform release (native library download + packaging) is driven by the GitHub Actions workflow in the main repo:

```bash
gh workflow run build.yaml \
  -f lib_version=<native lib version> \
  -f create_release=true \
  -f release_tag=v<version>
```

---

## 7. Pre-commit checks

CI (`.github/workflows/ci.yml`) runs the following checks, so **run them locally before committing**:

```bash
fvm flutter analyze --no-fatal-infos
fvm dart format --set-exit-if-changed lib/
fvm flutter build apk --release    # optional: verify it still builds
```

Format (write changes back):

```bash
fvm dart format lib/
```

---

## 8. Troubleshooting

**Q: Startup fails with `Failed to load dynamic library 'http_proxy.dll'` / symbol not found**
- Confirm the native library is at the correct path from §4.1 (on Windows it is the top-level `native/windows/x64/`, **not** `windows/native/`).
- Confirm the library architecture matches the target (x64 vs arm64).
- After rebuilding, re-run `flutter run` so CMake copies the fresh artifact.

**Q: `fvm flutter` uses the wrong version / cannot find the SDK**
- Run `fvm use 3.38.6` inside `ui/flutter` and confirm a `.fvmrc` was created.
- If the IDE doesn't pick it up, check that `dart.flutterSdkPath` points to `.fvm/flutter_sdk`.

**Q: fvm is extremely slow installing Flutter**
- It is cloning the full Flutter git mirror and downloading engine artifacts — this is normal. Configure the proxy from §3 to speed it up. Use `du -sh $FVM_CACHE_PATH` to confirm it is still growing (i.e. not actually stuck).

**Q: Setting the system proxy fails (desktop)**
- Make sure the main repo's `deps/sysproxy-rs` submodule is initialized; some systems require administrator privileges.
