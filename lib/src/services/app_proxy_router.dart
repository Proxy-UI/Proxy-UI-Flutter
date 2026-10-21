import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/proxy_launcher.dart';
import 'proxy_server_socket.dart';

/// Claude gives its agent one fixed proxy, not a per-request PAC evaluator.
/// Route here so the same host rules apply to both the app and its agent.
/// dart:io owns HTTP framing; HTTPS is an opaque CONNECT tunnel.
class AppProxyRouter {
  AppProxyRouter(this.configuration);

  ProxyLauncher configuration;
  HttpServer? _server;
  ServerSocket? _listener;
  final _sockets = <Socket>{};
  final _clients = <HttpClient>{};
  int _active = 0;

  int get port => _server!.port;

  Future<void> start([int port = 0]) async {
    _listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _server = HttpServer.listenOn(ProxyServerSocket(_listener!));
    _server!.idleTimeout = const Duration(seconds: 30);
    _server!.listen(_handle);
  }

  bool bypasses(String host) {
    host = host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') {
      return true;
    }
    return configuration.bypassRules.any((rule) {
      if (rule == '[::1]') return host == '::1';
      if (rule.startsWith('.')) {
        return host == rule.substring(1) || host.endsWith(rule);
      }
      return _matches(rule, host);
    });
  }

  static bool _matches(String pattern, String host) {
    // Host globs have only '*'. Avoid regex backtracking for user-authored
    // patterns with many stars; both strings are bounded host-sized inputs.
    var p = 0, h = 0, star = -1, retry = 0;
    while (h < host.length) {
      if (p < pattern.length && pattern[p] == host[h]) {
        p++;
        h++;
      } else if (p < pattern.length && pattern[p] == '*') {
        star = p++;
        retry = h;
      } else if (star >= 0) {
        p = star + 1;
        h = ++retry;
      } else {
        return false;
      }
    }
    while (p < pattern.length && pattern[p] == '*') {
      p++;
    }
    return p == pattern.length;
  }

  static Uri _destination(HttpRequest request) {
    final uri = request.uri;
    if (uri.scheme != 'http' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535 ||
        (request.method == 'CONNECT' &&
            (!uri.hasPort || uri.path.isNotEmpty || uri.hasQuery))) {
      throw const FormatException('Expected an HTTP proxy destination.');
    }
    return uri;
  }

  Future<(Socket, Stream<List<int>>)> _connectThroughProxy(Uri uri) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      configuration.port,
      timeout: const Duration(seconds: 10),
    );
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final authority = '$host:${uri.port}';
    // dart:io's proxy client emits unbracketed IPv6 CONNECT authorities.
    // CONNECT switches to raw bytes after its response header; no HTTP message
    // body/framing is decoded here. All other HTTP uses HttpClient.
    socket.add(
      ascii.encode('CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n\r\n'),
    );
    final iterator = StreamIterator<List<int>>(socket);
    final header = <int>[];
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    try {
      while (await iterator.moveNext().timeout(
        deadline.difference(DateTime.now()),
      )) {
        final chunk = iterator.current;
        for (var i = 0; i < chunk.length; i++) {
          header.add(chunk[i]);
          if (header.length > 32768) {
            throw const HttpException('Proxy response header too large.');
          }
          final n = header.length;
          if (n < 4 ||
              header[n - 4] != 13 ||
              header[n - 3] != 10 ||
              header[n - 2] != 13 ||
              header[n - 1] != 10) {
            continue;
          }
          if (!RegExp(r'^HTTP/1\.[01] 2[0-9]{2} ')
              .hasMatch(latin1.decode(header))) {
            throw const HttpException('Upstream proxy refused the tunnel.');
          }
          Stream<List<int>> remaining() async* {
            try {
              if (i + 1 < chunk.length) yield chunk.sublist(i + 1);
              while (await iterator.moveNext()) {
                yield iterator.current;
              }
            } finally {
              await iterator.cancel();
            }
          }

          return (socket, remaining());
        }
      }
      throw const HttpException('Incomplete proxy response.');
    } catch (_) {
      socket.destroy();
      await iterator.cancel();
      rethrow;
    }
  }

  Future<void> _handle(HttpRequest incoming) async {
    if (_active >= 128) {
      incoming.response.statusCode = HttpStatus.serviceUnavailable;
      await incoming.response.close();
      return;
    }
    _active++;
    HttpClient? client;
    Socket? downstream;
    Socket? upstream;
    try {
      final uri = _destination(incoming);
      // Never forward back to this listener, including through DNS aliases.
      if (uri.port == port || configuration.port == port) {
        throw const FormatException('Recursive proxy destination.');
      }
      final direct = bypasses(uri.host);
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10)
        ..autoUncompress = false
        ..userAgent = null
        ..findProxy = (_) =>
            direct ? 'DIRECT' : 'PROXY 127.0.0.1:${configuration.port}';
      _clients.add(client);
      if (incoming.method == 'CONNECT') {
        Stream<List<int>> incomingBytes;
        if (direct) {
          upstream = await Socket.connect(
            uri.host,
            uri.port,
            timeout: const Duration(seconds: 10),
          );
          incomingBytes = upstream.cast<List<int>>();
        } else {
          final tunnel = await _connectThroughProxy(uri);
          upstream = tunnel.$1;
          incomingBytes = tunnel.$2;
        }
        _sockets.add(upstream);
        incoming.response.statusCode = HttpStatus.ok;
        downstream = await incoming.response.detachSocket();
        _sockets.add(downstream);
        await Future.wait([
          incomingBytes.pipe(downstream),
          downstream.cast<List<int>>().pipe(upstream),
        ], eagerError: true);
      } else {
        incoming.response.persistentConnection = false;
        final outgoing = await client.openUrl(incoming.method, uri);
        outgoing.followRedirects = false;
        _copyHeaders(incoming.headers, outgoing.headers);
        // HttpClient derives Host from the validated absolute request target.
        outgoing.headers
          ..host = uri.host
          ..port = uri.port;
        await outgoing.addStream(incoming);
        final response = await outgoing.close().timeout(
          const Duration(seconds: 30),
        );
        incoming.response.statusCode = response.statusCode;
        _copyHeaders(response.headers, incoming.response.headers);
        await incoming.response.addStream(response);
        await incoming.response.close();
      }
    } catch (error) {
      if (downstream == null) {
        try {
          incoming.response.statusCode = error is FormatException
              ? HttpStatus.badRequest
              : HttpStatus.badGateway;
          incoming.response.persistentConnection = false;
          await incoming.response.close();
        } catch (_) {
          // The peer may already have disconnected.
        }
      }
    } finally {
      for (final socket in [downstream, upstream]) {
        socket?.destroy();
        _sockets.remove(socket);
      }
      client?.close(force: true);
      _clients.remove(client);
      _active--;
    }
  }

  static void _copyHeaders(HttpHeaders source, HttpHeaders target) {
    final excluded = {
      'connection',
      'proxy-connection',
      'proxy-authorization',
      'proxy-authenticate',
      'keep-alive',
      'transfer-encoding',
      'te',
      'trailer',
      'upgrade',
      ...?source[HttpHeaders.connectionHeader]
          ?.expand((value) => value.toLowerCase().split(','))
          .map((value) => value.trim()),
    };
    source.forEach((name, values) {
      if (!excluded.contains(name.toLowerCase())) target.set(name, values);
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
    await _listener?.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _server = null;
  }
}
