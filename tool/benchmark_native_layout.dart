// Compile with `fvm dart compile exe tool/benchmark_native_layout.dart`.
// Pass a freshly built release native library as the only argument.
// This compares AOT Dart with release Rust including buffer/FFI overhead.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:proxy_ui/src/screens/nodes/galaxy/galaxy_layout.dart';

List<double> reference(List<String> codes, List<double> seeds) {
  final xs = {for (var i = 0; i < codes.length; i++) codes[i]: seeds[i * 3]};
  final zs = {
    for (var i = 0; i < codes.length; i++) codes[i]: seeds[i * 3 + 1],
  };
  final extents = {
    for (var i = 0; i < codes.length; i++) codes[i]: seeds[i * 3 + 2],
  };
  final seedX = Map.of(xs), seedZ = Map.of(zs);
  for (var iteration = 0; iteration < 240; iteration++) {
    for (final c in codes) {
      xs[c] = xs[c]! + (seedX[c]! - xs[c]!) * 0.015;
      zs[c] = zs[c]! + (seedZ[c]! - zs[c]!) * 0.015;
      final r = math.sqrt(xs[c]! * xs[c]! + zs[c]! * zs[c]!);
      final minimum = extents[c]! + 1.5;
      if (r < minimum) {
        if (r < 1e-6) {
          xs[c] = minimum;
          zs[c] = 0;
        } else {
          xs[c] = xs[c]! * minimum / r;
          zs[c] = zs[c]! * minimum / r;
        }
      }
    }
    var moved = false;
    for (var i = 0; i < codes.length; i++) {
      for (var j = i + 1; j < codes.length; j++) {
        final a = codes[i], b = codes[j];
        var dx = xs[b]! - xs[a]!, dz = zs[b]! - zs[a]!;
        var d = math.sqrt(dx * dx + dz * dz);
        final need = extents[a]! + extents[b]! + 0.5;
        if (d >= need) continue;
        if (d < 1e-6) {
          var hash = 0x811c9dc5;
          for (final unit in '$a|$b'.codeUnits) {
            hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
          }
          final angle = (hash & 0xffffff) / 0x1000000 * math.pi * 2;
          dx = math.cos(angle);
          dz = math.sin(angle);
          d = 1;
        } else {
          dx /= d;
          dz /= d;
        }
        final push = (need - d) / 2;
        xs[a] = xs[a]! - dx * push;
        zs[a] = zs[a]! - dz * push;
        xs[b] = xs[b]! + dx * push;
        zs[b] = zs[b]! + dz * push;
        moved = true;
      }
    }
    if (!moved) break;
  }
  return [
    for (final c in codes) ...[xs[c]!, zs[c]!],
  ];
}

void main(List<String> args) {
  final native = NativeGalaxyLayout(library: DynamicLibrary.open(args.single));
  final codes = [
    for (var i = 0; i < 48; i++)
      String.fromCharCodes([65 + i ~/ 26, 65 + i % 26]),
  ];
  final seeds = [
    for (var i = 0; i < codes.length; i++) ...[
      math.sin(i * 0.2) * 4,
      math.cos(i * 0.2) * 4,
      0.8 + (i % 4) * 0.2,
    ],
  ];
  final expected = reference(codes, seeds);
  final actual = native.place(codes, seeds)!;
  for (var i = 0; i < actual.length; i++) {
    if ((actual[i] - expected[i]).abs() > 1e-8) {
      throw StateError('Layout differs at $i');
    }
  }
  double measure(List<double> Function(List<double>) operation) {
    final samples = <int>[];
    var checksum = 0.0;
    for (var i = 0; i < 55; i++) {
      final input = List<double>.of(seeds)..[0] += i * 0.00001;
      final watch = Stopwatch()..start();
      final result = operation(input);
      watch.stop();
      checksum += result.first;
      if (i >= 5) samples.add(watch.elapsedMicroseconds);
    }
    if (!checksum.isFinite) throw StateError('Invalid output');
    samples.sort();
    return samples[samples.length ~/ 2].toDouble();
  }

  final dart = measure((input) => reference(codes, input));
  final rust = measure((input) => native.place(codes, input)!);
  native.place(codes, seeds);
  final cached = measure((_) => native.place(codes, seeds)!);
  stdout.writeln(
    jsonEncode({
      'countries': codes.length,
      'samples': 50,
      'dart_aot_median_us': dart,
      'rust_including_ffi_median_us': rust,
      'cached_median_us': cached,
      'speedup': dart / rust,
    }),
  );
}
