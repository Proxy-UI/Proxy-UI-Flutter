import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';

// Opt in with an absolute path to a freshly built DLL. This tests Dart's real
// struct layout against Rust using ephemeral loopback listeners only. It never
// enables TUN, system proxy, auto-proxy, or an application cache directory.
void main() {
  final path = Platform.environment['PROXY_NATIVE_TEST_DLL'];
  test(
    'V8 DNS flags and the V7 prefix interoperate with the native library',
    () {
      final library = DynamicLibrary.open(path!);
      final create = library
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'proxy_create',
          );
      final destroy = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('proxy_destroy');
      final startV8 = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<ProxyConfigV8>),
            int Function(Pointer<Void>, Pointer<ProxyConfigV8>)
          >('proxy_start_v8');
      final startV7 = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<ProxyConfigV7>),
            int Function(Pointer<Void>, Pointer<ProxyConfigV7>)
          >('proxy_start_v7');
      final stop = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('proxy_stop');
      final isTunRunning = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('proxy_is_tun_running');
      final handle = create();
      expect(handle, isNot(nullptr));
      final config = calloc<ProxyConfigV8>();
      final host = '127.0.0.1'.toNativeUtf8();
      try {
        config.ref.base.base.serverHost = host;
        config.ref.base.base.serverPort = 9;
        // calloc keeps localPort = 0, binding an available loopback port.
        for (final protocol in [0, 3]) {
          config.ref.base.wireProtocol = protocol;
          for (final fakeIp in [0, 1]) {
            config.ref.tunFakeIp = fakeIp;
            expect(startV8(handle, config), ProxyResult.ok);
            expect(isTunRunning(handle), 0);
            expect(stop(handle), ProxyResult.ok);
          }
          expect(startV7(handle, config.cast<ProxyConfigV7>()), ProxyResult.ok);
          expect(stop(handle), ProxyResult.ok);
        }
        config.ref.tunFakeIp = 2;
        expect(startV8(handle, config), ProxyResult.invalidParam);
        config.ref.tunFakeIp = 0;
        config.ref.base.wireProtocol = 99;
        expect(startV8(handle, config), ProxyResult.invalidParam);
        expect(isTunRunning(handle), 0);
      } finally {
        destroy(handle);
        calloc.free(host);
        calloc.free(config);
      }
    },
    skip: path == null
        ? 'Set PROXY_NATIVE_TEST_DLL to test the release ABI'
        : false,
  );
}
