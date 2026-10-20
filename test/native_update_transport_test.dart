import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/updates/native_update_transport.dart';

void main() {
  final path = Platform.environment['CIPHERRELAY_NATIVE_TEST_LIB'];
  test(
    'native callbacks download, verify and cancel through the real ABI',
    () async {
      final transport = NativeUpdateTransport(
        library: DynamicLibrary.open(path!),
      );
      final work = await Directory.systemTemp.createTemp('native-update-test-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = List<int>.generate(256 * 1024, (i) => i % 251);
      server.listen((request) async {
        if (request.uri.path == '/stall') {
          request.response.contentLength = 100;
          request.response.add([1]);
          await request.response.flush();
          return;
        }
        request.response.contentLength = payload.length;
        request.response.add(payload);
        await request.response.close();
      });
      try {
        final target = File('${work.path}/update.apk');
        final events = <Map<String, dynamic>>[];
        final complete = await transport.start({
          'operation': 'download',
          'url': 'http://127.0.0.1:${server.port}/',
          'target': target.path,
          'size': payload.length,
          'sha256': sha256.convert(payload).toString(),
        }, onProgress: events.add).result;
        expect(complete['received'], payload.length);
        expect(await target.readAsBytes(), payload);
        expect(events, isNotEmpty);
        final pair = await Ed25519().newKeyPair();
        await transport.start({
          'operation': 'verify_signature',
          'body': base64Encode(payload),
          'signature': base64Encode(
            (await Ed25519().sign(payload, keyPair: pair)).bytes,
          ),
          'public_key': base64Encode((await pair.extractPublicKey()).bytes),
        }).result;
        final cancelled = transport.start({
          'operation': 'download',
          'url': 'http://127.0.0.1:${server.port}/stall',
          'target': '${work.path}/cancel.apk',
          'size': 100,
          'sha256': '0' * 64,
        });
        final expectation = expectLater(
          cancelled.result,
          throwsA(isA<UpdateCancelled>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        cancelled.cancel();
        await expectation;
        expect(await File('${work.path}/cancel.part').exists(), isFalse);
      } finally {
        await server.close(force: true);
        await work.delete(recursive: true);
      }
    },
    skip: path == null
        ? 'Set CIPHERRELAY_NATIVE_TEST_LIB to a freshly built library'
        : false,
  );
}
