import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../ffi/proxy_ffi.dart';
import 'release_manifest.dart';

typedef _Callback = Void Function(Uint64, Pointer<Utf8>);
typedef _StartNative = Uint64 Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _Start = int Function(
  Pointer<Utf8>,
  Pointer<NativeFunction<_Callback>>,
);
typedef _CancelNative = Void Function(Uint64);
typedef _FreeNative = Void Function(Pointer<Utf8>);

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class UpdateOperation {
  const UpdateOperation(this.result, this.cancel);
  final Future<Map<String, dynamic>> result;
  final void Function() cancel;
}

/// Injectable at the FFI boundary so UI tests need no platform native library.
abstract interface class UpdateTransport {
  UpdateOperation start(
    Map<String, Object?> request, {
    void Function(Map<String, dynamic>)? onProgress,
  });
}

class _Pending {
  _Pending(this.onProgress);
  final void Function(Map<String, dynamic>)? onProgress;
  final completer = Completer<Map<String, dynamic>>();
}

/// One callback and native runtime serve all downloads. Rust owns the HTTP
/// connection, bounded buffers, incremental hash and cancellation token.
class NativeUpdateTransport implements UpdateTransport {
  NativeUpdateTransport({DynamicLibrary? library})
    : _library = library ?? ProxyFFI().lib;

  static UpdateTransport? _shared;
  static UpdateTransport get shared => _shared ??= NativeUpdateTransport();

  final DynamicLibrary _library;
  final _pending = <int, _Pending>{};
  late final _start = _library.lookupFunction<_StartNative, _Start>(
    'proxy_update_start_v1',
  );
  late final _cancel = _library
      .lookupFunction<_CancelNative, void Function(int)>(
        'proxy_update_cancel_v1',
      );
  late final _free = _library
      .lookupFunction<_FreeNative, void Function(Pointer<Utf8>)>(
        'proxy_update_free_event_v1',
      );
  late final _callback = NativeCallable<_Callback>.listener(_onEvent)
    ..keepIsolateAlive = false;

  @override
  UpdateOperation start(
    Map<String, Object?> request, {
    void Function(Map<String, dynamic>)? onProgress,
  }) {
    final pending = _Pending(onProgress);
    final encoded = jsonEncode(request).toNativeUtf8();
    int id;
    try {
      id = _start(encoded, _callback.nativeFunction);
    } finally {
      calloc.free(encoded);
    }
    if (id == 0) {
      throw const UpdateException(
        UpdateFailure.install,
        'Native update request was rejected',
      );
    }
    // NativeCallable.listener delivers on this isolate after start returns.
    _pending[id] = pending;
    return UpdateOperation(pending.completer.future, () => _cancel(id));
  }

  void _onEvent(int id, Pointer<Utf8> pointer) {
    try {
      final event = jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
      final pending = _pending[id];
      if (pending == null) return;
      if (event['type'] == 'progress') {
        pending.onProgress?.call(event['data'] as Map<String, dynamic>);
        return;
      }
      _pending.remove(id);
      if (event['type'] == 'complete') {
        pending.completer.complete(event['data'] as Map<String, dynamic>);
      } else if (event['kind'] == 'cancelled') {
        pending.completer.completeError(const UpdateCancelled());
      } else {
        pending.completer.completeError(
          UpdateException(switch (event['kind']) {
            'signature' => UpdateFailure.signature,
            'checksum' => UpdateFailure.checksum,
            'install' => UpdateFailure.install,
            _ => UpdateFailure.network,
          }, event['message'] as String?),
        );
      }
    } finally {
      _free(pointer);
    }
  }
}
