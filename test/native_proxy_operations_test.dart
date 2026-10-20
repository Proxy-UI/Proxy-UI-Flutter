import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/native_proxy_operations.dart';

void main() {
  final path = Platform.environment['CIPHERRELAY_NATIVE_TEST_LIB'];
  test(
    'native worker callbacks retain handles and own subscription lifetime',
    () async {
      final library = DynamicLibrary.open(path!);
      final operations = NativeProxyOperations(library: library);
      final create = library
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
            'proxy_create',
          );
      final handle = create();
      expect(handle, isNot(nullptr));
      final cache = await Directory.systemTemp.createTemp('native-start-');
      final reservation = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = reservation.port;
      await reservation.close();
      try {
        final started = await operations.run(
          'start',
          handle: handle,
          arguments: {
            'config': {
              'server_host': '127.0.0.1',
              'server_port': port,
              'local_port': port,
              'session_key': null,
              'cache_directory': cache.path,
              'auto_proxy': false,
              'udp_enabled': false,
              'udp_direct_fallback': false,
              'tun_enabled': false,
              'tun_fake_ip': false,
              'tun_dns_server': '223.5.5.5',
              'tun_bypass_processes': <String>[],
              'reverse_geo': false,
              'secure_transport': true,
              'set_system_proxy': false,
              'allow_lan': false,
            },
          },
        );
        expect(started['code'], 0);
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        socket.destroy();
        final pending = operations.run('stop', handle: handle);
        // A listener callback returns through Dart's event loop, never synchronously.
        var completed = false;
        unawaited(pending.then((_) => completed = true));
        expect(completed, isFalse);
        await pending;
        for (var i = 0; i < 30; i++) {
          await operations.run('stop_tun', handle: handle);
        }
      } finally {
        await operations.run('destroy', handle: handle);
        await cache.delete(recursive: true);
      }
      final listener = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      await listener.close();
      await expectLater(
        operations.run('stop'),
        throwsA(isA<NativeOperationRejected>()),
      );
      final server = await operations.run(
        'start_subscription',
        arguments: {
          'port': 0,
          'config': {
            'local_port': 1080,
            'server_host': 'proxy.example',
            'udp_enabled': true,
            'reverse_geo': false,
          },
        },
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final response = await (await client.getUrl(
          Uri.parse('http://127.0.0.1:${server['port']}/clash'),
        )).close();
        expect(response.statusCode, 200);
        await response.drain<void>();
      } finally {
        client.close(force: true);
        await operations.run(
          'stop_subscription',
          arguments: {'id': server['id']},
        );
      }
      final rebound = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        server['port'] as int,
      );
      await rebound.close();
    },
    skip: path == null
        ? 'Set CIPHERRELAY_NATIVE_TEST_LIB to the fresh library'
        : false,
  );
}
