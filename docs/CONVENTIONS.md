# Project Conventions

This document defines the directory structure, state management, FFI integration, naming, and coding style for `proxy_ui`. **New code should follow the existing patterns.** For environment and run instructions, see [DEVELOPMENT.md](./DEVELOPMENT.md).

---

## 1. Directory structure and layering

```
lib/
├── main.dart                 # Entry: window/tray init, Provider registration, MaterialApp
└── src/
    ├── constants.dart        # Global constants: breakpoints, spacing, durations, color seeds, log levels
    ├── ffi/                  # Native library bridge (see §3)
    │   ├── proxy_ffi.dart    #   Low-level FFI bindings (DynamicLibrary / lookupFunction)
    │   └── proxy_service.dart#   High-level service wrapper (handle management, log stream, string codec)
    ├── models/               # Pure data models (fromJson/toJson, no UI, no side effects)
    ├── providers/            # State layer (ChangeNotifier, see §2)
    ├── screens/              # Page-level widgets (one page per file)
    ├── services/             # Business services (subscription, config generation, system tray, ...), no UI
    ├── utils/                # Pure utility functions
    └── widgets/              # Reusable UI components (dialogs, cards, ...)
```

**Dependency direction** (upper layers depend on lower layers, never the reverse):

```
screens / widgets  →  providers  →  services / ffi  →  models
```

- `models` depend on nothing above them and contain no Flutter UI types (except where genuinely needed, e.g. `Color`).
- `services` / `ffi` must not `import 'package:flutter/material.dart'` (use `foundation.dart` instead).
- The UI layer (`screens`/`widgets`) does not call `ffi` directly — always go through `providers`.

---

## 2. State management (provider + ChangeNotifier)

Use [`provider`](https://pub.dev/packages/provider) consistently. Global state is registered in the `MultiProvider` in `main.dart` (currently `ProxyState` and `ThemeState`).

### Rules

- **Naming:** state classes end with `State` (`ProxyState`, `ThemeState`); files live in `providers/` and end with `_provider.dart`.
- **Encapsulation:** fields are private (`_foo`); expose **getters** only. Expose mutable collections via `List.unmodifiable(...)` — never hand out the internal list for external mutation.
  ```dart
  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);
  ```
- **Notifying:** call `notifyListeners()` after any state change that affects the UI.
- **Initialization:** do asynchronous setup (e.g. reading `SharedPreferences`, subscribing to the log stream) in a private `_init()` called from the constructor.
- **Cleanup:** cancel/release held `StreamSubscription`s and handles in `dispose()`.
- **Consuming in the UI:** use `Consumer<T>` or `context.watch<T>()` to observe and `context.read<T>()` to trigger actions; avoid `read`-ing in `build` and then depending on its changes.

---

## 3. FFI integration

The native bridge is split into two layers with **strictly separated responsibilities**:

| Layer | File | Responsibility |
|-------|------|----------------|
| Low-level bindings | `ffi/proxy_ffi.dart` | `DynamicLibrary` loading, `lookupFunction` symbol binding, `typedef` signatures. **No business logic.** |
| High-level service | `ffi/proxy_service.dart` | Handle lifecycle, pointer/string codec, log stream, a Dart-friendly API for `providers` |

### Rules

- **Centralized loading:** library loading lives only in `_loadLibrary()` in `proxy_ffi.dart`, returning the correct file name per platform (see that file). Extend it here when adding a platform.
- **Memory ownership:** any string/struct allocated by Rust and returned to Dart **must** be released via the corresponding `proxy_free_*` (e.g. `proxyFreeString(message)` in the log callback). Document the allocate/free boundary in comments.
- **Thread-safe callbacks:** callbacks invoked from native threads must use `NativeCallable<...>.listener` (see `initLogging()`). **Do not** use `Pointer.fromFunction` for cross-thread callbacks.
- **String codec:** use `package:ffi`'s `toNativeUtf8()` / `toDartString()`, paired with `malloc.free` / `proxy_free_string`.
- **Error handling:** convert FFI return codes into Dart `bool`/exceptions/nullable values in `proxy_service.dart` — never leak raw return codes to the UI.
- The full steps for adding a native function are in §9.

---

## 4. Naming and code style

Follow [Effective Dart](https://dart.dev/effective-dart) and `flutter_lints` (see §7).

- **File names:** `snake_case` (`proxy_provider.dart`, `node_group_model.dart`).
- **Type names:** `PascalCase`. Models use `XxxModel` (`ProxyConfigModel`) or `XxxInfo` (`NodeInfo`); state uses `XxxState`; services use `XxxService`.
- **Members/variables/functions:** `lowerCamelCase`; private members prefixed with `_`.
- **Constants:** top-level `const` in `lowerCamelCase` (`mediumSpacing`, `shortDuration`), collected in `constants.dart` — **no scattered magic numbers**.
- **Enums:** `PascalCase` name + `lowerCamelCase` members; may carry fields (see `ColorSeed`, `LayoutStatus`).
- **Strings:** prefer **single quotes** `'...'`.
- **Prefer immutability:** use `const` wherever possible (widget constructors, `EdgeInsets`, etc.).
- **Doc comments:** use `///` on public classes and public methods to describe intent.
- **Import order:** `dart:` → `package:` → project-relative imports, separated by blank lines.

---

## 5. UI / theming / responsiveness

- **Material 3:** `useMaterial3: true`; colors come from `colorSchemeSeed` (taken from `ThemeState.colorSeed`, candidates in the `ColorSeed` enum); light/dark is driven by `ThemeState.themeMode`.
- **Spacing/animation:** always use the values in `constants.dart` (`tinySpacing`/`smallSpacing`/..., `shortDuration`/..., `navCurve`) — no hard-coded values.
- **Responsiveness:** adapt phone/tablet/desktop layouts using the breakpoints in `constants.dart` (`smallWidthBreakpoint`, etc.) and `LayoutStatus`.
- **Pages:** each page is its own file under `screens/`; extract reusable fragments into `widgets/`.

---

## 6. Models and persistence

- **Models** (`models/`): pure data with `fromJson` / `toJson`; no UI, no IO.
- **Persistence:** use `shared_preferences`; declare keys as **private static constants** in one place (e.g. `ProxyState._configKey = 'proxy_config'`) rather than repeating bare string keys.
- **Bounded growth:** in-memory collections that can grow must have a cap (e.g. logs `maxLogs = 1000`, dropping the oldest beyond it).

---

## 7. Lint and formatting

- Lint rules: `analysis_options.yaml` includes `package:flutter_lints/flutter.yaml` (`flutter_lints ^5`), currently the default set. Add/remove rules under `linter.rules` and explain the reason in the PR.
- **Must pass before committing** (matches CI):
  ```bash
  fvm flutter analyze --no-fatal-infos
  fvm dart format --set-exit-if-changed lib/
  ```
- To locally suppress a single lint use `// ignore: rule_name` or file-level `// ignore_for_file: rule_name`, with a nearby reason — avoid disabling rules globally.

---

## 8. Commit and branch conventions

- **Branches:** `main` (stable), `dev` (development); cut feature branches from `dev` and PR back into `dev`. CI triggers on push/PR to `main`/`dev`.
- **Commit messages:** follow [Conventional Commits](https://www.conventionalcommits.org/), consistent with the main repo: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, etc.
- **Native library version:** when upgrading the native library, also bump `LIB_VERSION` in CI (`.github/workflows/ci.yml`).
- **Submodule:** this repo is consumed as a submodule of proxy-everything; bump the submodule pointer there in a separate commit.

---

## 9. Recipes

### Add a page
1. Create `xxx_page.dart` under `screens/`, class `XxxPage extends StatelessWidget/StatefulWidget`.
2. Read data via `Consumer<SomeState>` / `context.watch`; trigger actions via `context.read<SomeState>().doX()`.
3. Use spacing/animation constants from `constants.dart`; wire navigation into `home_screen.dart`.

### Add a piece of state
1. Create `xxx_provider.dart` under `providers/`, `class XxxState extends ChangeNotifier`.
2. Private fields + getters + `notifyListeners()`; async init in `_init()`, release resources in `dispose()`.
3. Register it in the `MultiProvider` in `main.dart`: `ChangeNotifierProvider(create: (_) => XxxState())`.

### Add a native (FFI) function
1. **Rust side:** export it in `crates/proxy-ffi/src/` with `#[unsafe(no_mangle)] pub extern "C" fn proxy_xxx(...)`; provide a `proxy_free_xxx` for any memory handed to Dart.
2. **Low-level binding:** add the `typedef`s (Native + Dart signatures) and `lookupFunction` binding in `proxy_ffi.dart`.
3. **High-level wrapper:** add a method in `proxy_service.dart` that handles pointer/string codec and memory release, returning a Dart-friendly type.
4. **State integration:** call it from the relevant `providers/`; the UI uses it through the provider — **the UI never touches FFI directly**.
5. Rebuild the native library and place it in the matching `native/` directory (see [DEVELOPMENT.md §4](./DEVELOPMENT.md)).
