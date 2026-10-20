import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'proxy_ffi.dart';

typedef _Callback = Void Function(Uint64, Pointer<Utf8>);
typedef _StartNative = Uint64 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _Start = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _Free = Void Function(Pointer<Utf8>);

class NativeOperationRejected extends StateError {
  NativeOperationRejected(String operation)
    : super('Native operation rejected: $operation');
}

/// Shared native workers return one result to the UI. The caller's operation
/// queue retains each handle's exclusive borrow through completion.
class NativeProxyOperations {
  NativeProxyOperations({DynamicLibrary? library})
    : _library = library ?? ProxyFFI().lib;
  static NativeProxyOperations? _shared;
  static NativeProxyOperations get shared =>
      _shared ??= NativeProxyOperations();
  final DynamicLibrary _library;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final _start = _library.lookupFunction<_StartNative, _Start>(
    'proxy_operation_start_v1',
  );
  late final _free = _library
      .lookupFunction<_Free, void Function(Pointer<Utf8>)>('proxy_free_string');
  late final _callback = NativeCallable<_Callback>.listener(_onResult)
    ..keepIsolateAlive = false;

  Future<Map<String, dynamic>> run(
    String operation, {
    Pointer<Void>? handle,
    Map<String, Object?> arguments = const {},
  }) {
    final completer = Completer<Map<String, dynamic>>();
    final request = jsonEncode({'operation': operation, ...arguments})
        .toNativeUtf8();
    int id;
    try {
      id = _start(handle ?? nullptr, request, _callback.nativeFunction);
    } finally {
      calloc.free(request);
    }
    if (id == 0) {
      return Future.error(NativeOperationRejected(operation));
    }
    _pending[id] = completer;
    return completer.future;
  }

  void _onResult(int id, Pointer<Utf8> pointer) {
    try {
      final result = jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (result['type'] == 'complete') {
        completer.complete(result['data'] as Map<String, dynamic>);
      } else {
        completer.completeError(StateError('${result['message']}'));
      }
    } finally {
      _free(pointer);
    }
  }
}
