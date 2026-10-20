import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _LayoutNative = Int32 Function(Pointer<Uint8>, Uint32, Pointer<Double>);
typedef _Layout = int Function(Pointer<Uint8>, int, Pointer<Double>);

/// One cached layout, invalidated by topology or extents rather than health.
/// Invalid/legacy country codes retain the Dart compatibility implementation.
class NativeGalaxyLayout {
  NativeGalaxyLayout({DynamicLibrary? library}) {
    try {
      _layout = library?.lookupFunction<_LayoutNative, _Layout>(
        'proxy_galaxy_layout_v1',
      );
    } catch (_) {}
  }
  _Layout? _layout;
  List<String>? _codes;
  List<double>? _seeds;
  Float64List? _result;

  Float64List? place(List<String> codes, List<double> seeds) {
    if (_layout == null ||
        codes.length > 256 ||
        codes.any(
          (c) =>
              c.isNotEmpty &&
              (c.length != 2 || c.codeUnits.any((u) => u > 127 || u == 0)),
        )) {
      return null;
    }
    if (_codes != null &&
        codes.length == _codes!.length &&
        seeds.length == _seeds!.length &&
        Iterable<int>.generate(codes.length)
            .every((i) => codes[i] == _codes![i]) &&
        Iterable<int>.generate(seeds.length)
            .every((i) => seeds[i] == _seeds![i])) {
      return _result;
    }
    if (seeds.length != codes.length * 3) {
      throw ArgumentError('Each country needs x, z and extent');
    }
    final input = calloc<Uint8>(codes.length * 32);
    final output = calloc<Double>(codes.length * 2);
    try {
      final bytes = ByteData.sublistView(input.asTypedList(codes.length * 32));
      for (var i = 0; i < codes.length; i++) {
        for (var j = 0; j < 3; j++) {
          bytes.setFloat64(i * 32 + j * 8, seeds[i * 3 + j], Endian.host);
        }
        final code = codes[i];
        bytes.setUint32(
          i * 32 + 24,
          code.isEmpty ? 0 : (code.codeUnitAt(0) << 8) | code.codeUnitAt(1),
          Endian.host,
        );
      }
      if (_layout!(input, codes.length, output) != 0) {
        throw StateError('Invalid galaxy layout');
      }
      _codes = List.of(codes);
      _seeds = List.of(seeds);
      return _result = Float64List.fromList(
        output.asTypedList(codes.length * 2),
      );
    } finally {
      calloc.free(input);
      calloc.free(output);
    }
  }
}
