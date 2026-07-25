import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/proxy_config.dart';
import 'clash_config_generator.dart';
import 'local_network_service.dart';
import 'shadowrocket_config_generator.dart';

class SubscriptionService {
  SubscriptionService({LocalNetworkService? localNetworkService})
    : _localNetworkService = localNetworkService ?? LocalNetworkService();

  final LocalNetworkService _localNetworkService;
  HttpServer? _server;
  int _port = 8080;
  ProxyConfigModel? _config;

  Future<void> start(ProxyConfigModel config, int port) async {
    _config = config;
    _port = port;

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(_handleRequest);

    _server = await shelf_io.serve(handler, '0.0.0.0', port);
  }

  Response _handleRequest(Request request) {
    final path = request.url.path;

    if (path == 'clash') {
      final yaml = ClashConfigGenerator.generate(_config!);
      return Response.ok(
        yaml,
        headers: {
          'Content-Type': 'text/yaml; charset=utf-8',
          'Content-Disposition': 'attachment; filename=clash.yaml',
        },
      );
    }

    if (path == 'shadowrocket') {
      final content = ShadowrocketConfigGenerator.generate(
        _config!,
        base64Encode: false,
        reverseGeo: _config!.reverseGeo,
      );
      return Response.ok(
        content,
        headers: {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Disposition': 'attachment; filename=shadowrocket.conf',
        },
      );
    }

    if (path == 'shadowrocket/base64') {
      final content = ShadowrocketConfigGenerator.generate(
        _config!,
        base64Encode: true,
        reverseGeo: _config!.reverseGeo,
      );
      return Response.ok(
        content,
        headers: {'Content-Type': 'text/plain; charset=utf-8'},
      );
    }

    return Response.notFound('Not Found');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<String> getClashUrl() async {
    return '${await _getBaseUrl()}/clash';
  }

  Future<String> getShadowrocketUrl({bool base64 = false}) async {
    final baseUrl = await _getBaseUrl();
    return base64 ? '$baseUrl/shadowrocket/base64' : '$baseUrl/shadowrocket';
  }

  Future<String> _getBaseUrl() async {
    return await _localNetworkService.getHttpProxyUrl(_port) ??
        'http://127.0.0.1:$_port';
  }
}
