# Galaxy resource verification

The mobile dashboard only computes node summaries. Galaxy canvases are mounted
when their page is visible; the desktop dashboard retains its map. The canvas
stops scheduling frames when the camera and transitions settle. Interaction follows
screen vsync for a finite six-second ambient interval; camera integration clamps
long pauses without stretching the interaction. Reduced motion skips decorative
transitions. The Ticker is stopped entirely at rest, on backgrounding and disposal.

Native 0.6.5 adds the independent `galaxy-geometry` Rust crate. A single bounded,
allocation-free leaf FFI call projects and clips cached world-space orbit meshes
into reusable buffers. Near-plane and viewport clipping happen before drawing
or generating dashes. Older native libraries use a tested Dart fallback. Dart
owns and frees the buffers; there is no proxy runtime dependency or worker thread.
The real-library test compares Rust and Dart across 2,001 segments and 12 cameras.

The renderer batches visible lines, draws glows, shadows and spheres from one
cached sprite atlas ([below](#sprite-atlas)), culls offscreen bodies, and runs
no blur pass per frame. All canvas drawing is clipped to its viewport. These
changes apply to every platform, including Windows; GPU submission and CPU
geometry are both reduced.

The galaxy mutes itself from the application lifecycle. Every desktop embedder
derives that state from the native window: hidden to the tray or minimized is
`hidden`, unfocused is `inactive`, and a hidden engine draws no frames at all.
Nothing else is muted. An app-wide `TickerMode` gate with its own visibility
flag in Dart used to sit above the navigator. When the macOS Dock reopened the
window natively the flag stayed false, so page switches and dialogs never
appeared and the whole window looked frozen. Muting does not stop the proxy or
VPN. The connected power button pulses once, instead of animating for the
entire connection lifetime.

Each canvas owns its backdrop and sprite atlas. Flags are shared only while
at least one visible canvas uses them. A late backdrop or flag rasterization
discards its image after a visibility or theme change; the atlas renders
synchronously while painting, so it has no late completions, and a theme
change or hiding releases it. Labels dispose unused native paragraphs.
Background canvases cannot start new backdrop, flag or sprite renders.
Stable localized text and cached scenes prevent unrelated provider updates
from invalidating the map.

## Repeatable checks

From `ui/flutter`:

```sh
fvm flutter test test/galaxy_geometry_test.dart test/galaxy_render_lifecycle_test.dart test/galaxy_cache_test.dart test/planet_atlas_test.dart test/home_render_lifecycle_test.dart
fvm flutter test tool/render_galaxy_test.dart
```

The tests cover a populated connected map at rest, vsync interaction repaint
frequency, background/detached engines, navigation while unfocused, page
disposal, sprite release on hiding and theme change, sprites against vectors,
the atlas's memory bound, concurrent differently sized canvases, and unrelated
provider notifications. The render harness writes desktop/phone and dark/light
screenshots to `build/ui-shots/`.

Lifecycle and resting-map tests run with Windows, macOS, Linux, Android and iOS
platform variants. These tests exercise shared Dart behavior; they do not
replace native builds on macOS, Linux or iOS. Local native execution was
verified on Windows and Android.

`tool/galaxy_resource_probe.dart` is a separate benchmark entry point with 240
synthetic nodes in 12 countries and no proxy/network activity. Run on a dedicated
test device using FVM in release mode, after incrementing the Android build
number as required by the repository:

```sh
fvm flutter run --release -d <device> -t tool/galaxy_resource_probe.dart
```

The benchmark uses the application's package ID and signing key. It is not a
deliverable; build `lib/main.dart` for normal packages. Its Baseline/Galaxy and
Animate buttons produce 15-second `GALAXY_PROBE` logcat samples with frame count,
build/raster duration, and RSS. Button ripples and lifecycle transition frames
are included. For steady-state CPU, begin a separate `/proc/<pid>/stat` sample
after the transition settles. Compare user+system ticks for the same duration;
do not equate raster duration with device GPU utilization.

For Windows, use an isolated host so the installed client's single-instance
lock, settings and active proxy remain untouched. From `ui/flutter` in
PowerShell, create the host once:

```powershell
fvm flutter create --platforms windows --project-name galaxy_resource_probe --no-pub build/galaxy_windows_probe
Copy-Item .fvmrc, pubspec.lock build/galaxy_windows_probe/
Copy-Item tool/galaxy_resource_probe.dart build/galaxy_windows_probe/lib/main.dart
New-Item -ItemType Directory -Force build/galaxy_windows_probe/shaders
Copy-Item shaders/nebula.frag build/galaxy_windows_probe/shaders/
```

Replace the host's `pubspec.yaml` with:

```yaml
name: galaxy_resource_probe
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  flutter:
    sdk: flutter
  proxy_ui:
    path: ../..
  window_manager: ^0.5.2
flutter:
  uses-material-design: true
  shaders:
    - shaders/nebula.frag
```

Build using FVM in that host directory:

```powershell
fvm flutter pub get --offline
fvm flutter build windows --release --no-pub --dart-define=GALAXY_PROBE_OUTPUT=D:/rust_pro/proxy-everything/target/galaxy-performance/windows-probe.jsonl
```

Choose an existing output directory for the JSON-lines log. Launch the host's
`galaxy_resource_probe.exe`, then select **Run desktop suite**. The suite uses
real native focus, minimize, hide and restore calls, allows transitions to
settle, and collects 15-second idle/background samples plus an eight-second
interaction sample. It temporarily ignores pointer input inside the canvas
and controls so manual input cannot contaminate the automatic sequence. The
probe neither initializes the proxy service nor changes connection settings.
Sample the probe PID's `TotalProcessorTime` independently; sum across all its
threads and compare timestamps with each phase's `utc_ms` boundaries.

## Sprite atlas

`PlanetAtlas` (`planet_atlas.dart`) renders each layer of a sphere once into
one atlas image and draws the layers with `drawRawAtlas`, in the order the
painter issues them:

- `paintSphere` (`widgets/planet_glyph.dart`) builds a sphere from layers
  through `SphereLayers`: a blurred glow (dark) or contact shadow (light), the
  lit body, the rim light and the blurred specular point. `paintFlagSphere`
  builds a country's star the same way, with the flag's face and its shading
  in place of the body. `CanvasSphereLayers` draws the layers as vectors (list
  rows, legends, the first frame) and also paints the atlas cells, so each
  layer is defined once.
- Opacity stays per layer. A faded planet is four sprites, each at its own
  alpha, as translucent as the vector sphere; the earlier cache baked a whole
  sphere into one 256 px texture per colour and faded it as one image, so a
  faded planet hid its glow behind its body.
- Glows, shadows, rims, specular points and flag shading are white or fixed
  coverage images coloured when drawn (`BlendMode.modulate`). Bodies are
  rendered per colour, flags per country.
- Sharp layers are rendered per size bucket, four per octave of on-screen
  pixels, and drawn at most 16 % smaller than rendered (the earlier texture
  was drawn up to ten times smaller). Soft layers use two buckets per octave
  and are scaled up above 16 px (32 px for shadows).
- Glows are the blurred discs the vector painter defines, rendered once per
  bucket and relative blur (±2 %), not the radial-gradient ovals that stood in
  for them. The disk plane's glow is again the blurred oval: one image of its
  shape relative to its blur, stretched over the frame's oval, re-rendered
  only when that shape changes.
- Sprites are submitted in runs between vector draws (orbits, rings, arcs,
  ripples, glyphs, labels): the painter's canvas getter flushes queued sprites
  before any direct draw, so overlaps keep their order. The earlier batch
  grouped equal textures per flush, which drew a planet's glow over the
  testing arc and current-node ring drawn before it.
- A layer is painted as vectors in the frame that first asks for it; the end
  of that frame renders the atlas again with `toImageSync` (the previous image
  as it was plus the new cells, packed bottom-left on a skyline). There is no
  placeholder frame.

Memory: one atlas per visible canvas, at most 512×2048 pixels (4 MB), plus the
plane's small image. Image heights are rounded up to 64 rows (16 px for the
plane), so a replaced image leaves one the GPU can reuse. A full atlas starts
afresh at most every 600 frames and paints what does not fit as vectors in
between, so it never rebuilds every frame. The earlier cache kept one 256 KB
texture per colour, theme, glow and flag without a bound: the probe's busy
scene held 22 of them (5.5 MB). `PlanetAtlas.liveBytes` reports the current
total.

Look: `test/planet_atlas_test.dart` compares sprite-drawn spheres, flags and a
large glow with the vector layers at radii 2.4–26, opacities 1, 0.62 and 0.3,
overlapping a vector stroke, in both themes at 2×. The first frame is
identical; afterwards 0.15–0.19 % of channels differ by more than 8/255, on
anti-aliased edges and the stripes inside flags. Bodies that ignore their
opacity differ in about 3 %, and the test checks that this is caught.
Compared with build 2.0.6, glows and the plane's glow return to the blurred
shapes the gradients approximated; faded planets regain per-layer translucency.

Not measured: frame times and process footprint after this change. The probe's
raster suite (below) measured the earlier renderer once on macOS (Impeller on
Metal, 1280×720 at 2×, 120 Hz): raster 2.3–4.0 ms per frame typical and
4.1–8.0 ms busy, footprint 512–642 MB of which 129–167 MB GPU.

```sh
fvm flutter build macos --profile -t tool/galaxy_resource_probe.dart --dart-define=GALAXY_PROBE_SUITE=raster
```

The raster suite pins an 800×600 window on top of the main display (macOS
stops drawing a covered window, and another display may differ in pixel ratio
and refresh rate), retakes a sample drawn elsewhere or at a reduced rate, and
keeps focus changes from muting the galaxy. Each `GALAXY_PROBE` result reports
pixel ratio, refresh rate, frames, build/raster percentiles, RSS,
`sprite_bytes` and its window (`started_ms`–`utc_ms`) for an outside
`footprint -p <pid>` sampler, which also counts GPU (IOAccelerator) memory.

## Local measurements, 2026-10-20

Android 16 x86_64 emulator, 1080×2400, host GPU with Impeller OpenGLES. Compared
the same 240-node scene before and after the texture/halo rendering changes;
both samples already include idle suspension. One Animate action, 15-second
frame window and approximately 17-second process CPU window:

| Measure | Before texture/halo changes | Final |
| --- | ---: | ---: |
| Process CPU time | 16.10 s | 6.51 s |
| Cumulative raster duration | 14.18 s | 6.09 s |
| Mean raster duration per submitted frame | 122.2 ms | 60.9 ms |

The final populated map added zero CPU ticks during a 15-second steady idle
sample. A 15-second background frame sample recorded zero frames and zero
build/raster work, matching the empty baseline's background frame count.

These are emulator measurements, not physical-device FPS or battery estimates.
Flutter/graphics allocators retain memory after the first render: explicit
image disposal does not promise RSS returns to the pre-map baseline. Cache
ownership and disposal are tested independently; the measurements establish
absence of continuous galaxy work at rest/background, not zero process memory.

### Historical Windows x64 experiment, build 2.0.5+70

The isolated release host uses the same shared renderer, FVM SDK and locked
production dependencies, with 240 synthetic nodes and a 1280×720 window.
The installed client's existing process and proxy connection stayed running.
Comparing the first automatic eight-second interaction sample before and after
replacing the display-rate Ticker:

| Measure | Skipped paint callbacks on Ticker | Cadence timer |
| --- | ---: | ---: |
| Submitted Flutter frames | 794 | 182 |
| Cumulative raster duration | 5.63 s | 2.82 s |
| Process CPU time | 9.19 s | 4.52 s |

Process samples use `TotalProcessorTime`, sampled every 500 ms and matched to
the nearest phase boundary; their measured intervals are 7.81 and 7.76 seconds.
CPU time sums all process threads and may exceed elapsed time. Later manual
interaction in the first run is excluded from this comparison. These are
renderer-host measurements, not the CPU usage of a proxy carrying traffic.

Steady-state samples of that build, each approximately 15 seconds:

| Window state | Submitted frames | Process CPU time |
| --- | ---: | ---: |
| Empty foreground baseline | 0 | 0.31 s |
| Populated foreground galaxy | 0 | 0.41 s |
| Unfocused | 0 | 0.06 s |
| Minimized | 0 | 0.05 s |
| Restored after minimize | 0 | 0.38 s |
| Hidden in tray | 0 | 0.02 s |
| Shown again after tray hide | 0 | 0.39 s |

The restored scene was also inspected visually. Zero submitted frames means
no galaxy raster work in these samples, not zero process housekeeping or zero
resident memory. Windows retained graphics/allocator memory after hiding, as
Android did; cache disposal does not imply immediate working-set reclamation.
Logs and CPU samples are under the ignored `target/galaxy-performance/` folder.

The build 70 checks passed 167 Flutter tests (3 skipped), the 11-view render
harness, and analysis with 26 existing informational notices and no errors or
warnings. The root Windows release workflow rebuilt and staged the native
bundle; the complete x64 ZIP includes both proxy and Wintun DLLs. Android
build 70 split APKs retain the local certificate and increase effective version
codes to 1070 / 2070 / 4070. macOS, Linux and iOS behavior is covered by shared
platform-variant tests; native packages for those platforms were not built or
run on this Windows host.

## Hierarchy smoothness, 2.0.6+71 / native 0.6.5

The build 70 timer reduced total CPU but capped animation at 30 Hz and did not
fix slow country transitions. The new renderer follows display vsync while
active and stops at rest. The same Windows release host, 240 nodes, 12 countries,
1280×720 window and camera selections were measured before/after. Each sample
covers three seconds of country → node → country → overview, after an eight-second
scene warm-up. Camera easing was also shortened. These are frame timing samples,
not GPU utilization or guaranteed FPS on other hardware.

| Transition | Before raster p95 | After raster p95 | After UI build p95 |
| --- | ---: | ---: | ---: |
| AU-country | 48.73 ms | 15.17 ms | 1.62 ms |
| AU-node | 29.06 ms | 6.57 ms | 0.91 ms |
| AU-return-country | 43.12 ms | 11.69 ms | 1.55 ms |
| AU-overview | 37.18 ms | 15.65 ms | 1.68 ms |
| CA-country | 32.79 ms | 12.99 ms | 1.26 ms |
| CA-node | 16.23 ms | 3.72 ms | 0.63 ms |
| CA-return-country | 23.70 ms | 6.93 ms | 0.87 ms |
| CA-overview | 38.63 ms | 15.64 ms | 1.60 ms |

All eight final transition samples confirmed `native_geometry: true`; none had
a raster frame above 33.3 ms. Occasional 16.7 ms misses remain; these numbers do
not imply every frame meets a high-refresh display's smaller budget. The benchmark
runs without a proxy service and does not stop the installed client.

Use **Test hierarchy** in the probe, or build it with
`--dart-define=GALAXY_PROBE_SUITE=hierarchy` for an automatic sequence. JSONL output
includes p50, p95, maximum, counts above 16.7/33.3 ms and native geometry availability.
For the isolated Windows host, first stage a fresh native DLL using the root
`stage-ui-native.ps1` workflow, then copy that staged DLL beside the probe executable.
Ensure the host's dependencies are refreshed after an upstream dependency update.

The compute-only Rust benchmark measured about 49 µs for 4,096 segments and
140 µs for 16,384 on this host. This explains why GPU batching and cached lighting
made a larger end-to-end difference than introducing geometry worker threads.

## Testing many nodes

Testing a country used to keep the whole window drawing at display rate until
its slowest node timed out. Three things did it: the galaxy counted a probe in
flight as an animation and spun an arc around every node under test, each row
in the country panel and both test buttons showed an indeterminate spinner,
and every answer notified the provider and wrote the whole catalogue to
preferences on its own. Any animation makes the engine raster the entire
window again, galaxy included, so a test of 30 nodes with dead ones among them
rastered continuously for over twenty seconds.

Now nothing moves while probes wait. In-flight marks are still: a fixed arc
per planet, a fixed ring per row, and the share answered on the test buttons.
`ProxyState.verifyNodes` puts every node into the testing state in one update,
applies answers that arrive within 150 ms of each other as one more, and saves
the catalogue once per run. Starting and answering still ripple, so the
galaxy draws briefly when something changes. `ProxyService.probeNodes` uses the
native batch (`proxy_probe_nodes_v1`, 16 at a time) when the library exports
it; otherwise it probes eight at a time, one isolate each, as before. See the
parent repository's `docs/node-probe-batch.md` for the native contract.

`tool/node_test_burst_probe.dart` tests 30 nodes in one country of a 56-node
synthetic catalogue, with that country's panel open. Half answer within a
second and half run to the 10 s timeout. It changes no settings, and its
window stays on top with pointer input ignored inside, so a stray scroll
cannot start an interaction. `BURST_PATH` selects `isolate` (no native batch),
`batch` (a model of it) or `real` (the native batch against local ports that
refuse or never answer, which needs a freshly staged library):

```sh
fvm flutter run --profile -d macos -t tool/node_test_burst_probe.dart --dart-define=BURST_PATH=real
```

Measured on macOS (Apple silicon, 1440×900 at 2×), profile mode:

| Measure | Before | After, native batch |
| --- | ---: | ---: |
| Time until every node answered | 22.1 s | 10.0 s |
| Frames drawn | 2,839 | 360 |
| Frames drawn while only waiting | every vsync | 0 |
| Cumulative raster duration | 18.1 s | 3.3 s |
| Process CPU time | 32.4 s | 5.2 s |
| Provider notifications | 60 | 3 |
| Longest UI isolate stall | 124 ms | 12.7 ms |

Without the native batch, the same UI keeps the old timing (22.1 s, answers
in three waves) but draws only while answers arrive. Its 124 ms stall
coincides with the first wave of timed-out isolates returning together; no
run without isolates stalled for more than 31 ms. The figures are
single runs on one machine, not frame-rate guarantees; the ratio is what
carries over. `test/nodes_page_test.dart` checks that a country waiting on its
probes schedules no frames.

## Connection lifetime verification

Build 2.0.5+69 was also exercised with the real Android native library and VPN
service. A local test proxy forwarded HTTP to a loopback fixture. Requests
succeeded before backgrounding, while the Activity was absent after removing
its task from Recents, and after reopening the app. The process and foreground
VPN service remained the same, and the recreated dashboard showed Connected
with VPN enabled. Disconnect/reconnect controls remained usable afterward.

Android retains the Flutter engine with the process so the Dart isolate keeps
ownership of the live native handle. Initialization and resume reconcile the
UI against native state in both directions. This does not retain a VPN across
Android killing the entire process; in that case its native runtime ends too.
