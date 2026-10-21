import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/models/proxy_launcher.dart';
import 'package:proxy_ui/src/services/app_proxy_router.dart';
import 'package:proxy_ui/src/services/proxy_server_socket.dart';

ProxyLauncher settings(int port, [List<String>? rules]) => ProxyLauncher(
  name: 'Claude',
  appPath: '/Applications/Claude.app',
  applicationId: 'com.anthropic.claudefordesktop',
  mode: LauncherMode.claudeNative,
  port: port,
  bypassRules: rules ?? ProxyLauncher.defaultBypassRules,
);

void main() {
  test('routes HTTP and opaque CONNECT, strips proxy credentials, fails closed', () async {
    final upstreamSocket = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final upstream = HttpServer.listenOn(ProxyServerSocket(upstreamSocket));
    final direct = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final seen = <String>[];
    upstream.listen((request) async {
      seen.add(
        '${request.method} ${request.method == 'CONNECT' ? request.uri.authority : request.uri}',
      );
      expect(request.headers.value('proxy-authorization'), isNull);
      expect(request.headers.value('x-hop'), isNull);
      if (request.method == 'CONNECT') {
        final socket = await request.response.detachSocket();
        sockets.add(socket);
        socket.listen(socket.add);
      } else {
        final body = await utf8.decoder.bind(request).join();
        request.response.write('upstream:$body');
        await request.response.close();
      }
    });
    direct.listen((request) async {
      request.response.write('direct');
      await request.response.close();
    });
    echo.listen((socket) {
      sockets.add(socket);
      socket.listen(socket.add);
    });
    final router = AppProxyRouter(settings(upstream.port));
    await router.start();
    final client = HttpClient()
      ..findProxy = (_) => 'PROXY 127.0.0.1:${router.port}';
    addTearDown(() async {
      client.close(force: true);
      await router.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await upstream.close(force: true);
      await upstreamSocket.close();
      await direct.close(force: true);
      await echo.close();
    });
    expect(router.bypasses('Portal.OA.Example'), isTrue);
    expect(router.bypasses('EXAMPLE.COM'), isFalse);
    final request = await client.postUrl(
      Uri.parse('http://public.invalid/upload'),
    );
    request.headers
      ..set('proxy-authorization', 'test-only')
      ..set('connection', 'x-hop')
      ..set('x-hop', 'remove');
    request.write('payload');
    expect(
      await utf8.decoder.bind(await request.close()).join(),
      'upstream:payload',
    );
    final bypass = await client.getUrl(
      Uri.parse('http://127.0.0.1:${direct.port}/'),
    );
    expect(await utf8.decoder.bind(await bypass.close()).join(), 'direct');

    for (final target in [
      'public.invalid:443',
      '127.0.0.1:${echo.port}',
      '[2001:db8::1]:443',
    ]) {
      final socket = await Socket.connect('127.0.0.1', router.port);
      final input = StreamIterator(socket);
      // Exercise the actual authority-form request, including an IPv6 literal.
      socket.add(
        ascii.encode('CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n'),
      );
      var header = '';
      while (!header.endsWith('\r\n\r\n') &&
          await input.moveNext().timeout(const Duration(seconds: 3))) {
        header += ascii.decode(input.current);
      }
      expect(header, startsWith('HTTP/1.1 200 '));
      socket.add(utf8.encode('opaque tunnel bytes'));
      expect(
        await input.moveNext().timeout(const Duration(seconds: 3)),
        isTrue,
      );
      expect(utf8.decode(input.current), 'opaque tunnel bytes');
      socket.destroy();
      await input.cancel();
    }
    expect(seen, [
      'POST http://public.invalid/upload',
      'CONNECT public.invalid:443',
      'CONNECT [2001:db8::1]:443',
    ]);
    router.configuration = settings(upstream.port, ['*']);
    expect(router.bypasses('any.invalid'), isTrue);
    router.configuration = settings(upstream.port, []);
    expect(router.bypasses('oa.example'), isFalse);
    final recursive = await client.getUrl(
      Uri.parse('http://127.0.0.1:${router.port}/'),
    );
    final recursiveResponse = await recursive.close();
    expect(recursiveResponse.statusCode, HttpStatus.badRequest);
    await recursiveResponse.drain<void>();
    await upstream.close(force: true);
    await upstreamSocket.close();
    final unavailable = await client.getUrl(
      Uri.parse('http://public.invalid/'),
    );
    final unavailableResponse = await unavailable.close();
    expect(unavailableResponse.statusCode, HttpStatus.badGateway);
    await unavailableResponse.drain<void>();
  });
}
