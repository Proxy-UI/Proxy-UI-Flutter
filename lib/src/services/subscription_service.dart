import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../models/proxy_config.dart';
import 'clash_config_generator.dart';
import 'shadowrocket_config_generator.dart';

class SubscriptionService {
  HttpServer? _server;
  int _port = 8080;
  ProxyConfigModel? _config;

  Future<void> start(ProxyConfigModel config, int port) async {
    if (_server != null) {
      await stop();
    }

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
    final ip = await _getDeviceIp();
    return 'http://$ip:$_port/clash';
  }

  Future<String> getShadowrocketUrl({bool base64 = false}) async {
    final ip = await _getDeviceIp();
    return base64
        ? 'http://$ip:$_port/shadowrocket/base64'
        : 'http://$ip:$_port/shadowrocket';
  }

  Future<String> _getDeviceIp() async {
    try {
      final info = NetworkInfo();
      final wifiIP = await info.getWifiIP();
      return wifiIP ?? '127.0.0.1';
    } catch (e) {
      return '127.0.0.1';
    }
  }
}
