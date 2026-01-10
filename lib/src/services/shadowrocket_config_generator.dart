import 'dart:convert';

import '../models/proxy_config.dart';

class ShadowrocketConfigGenerator {
  static String generate(
    ProxyConfigModel config, {
    bool base64Encode = false,
    bool reverseGeo = false,
  }) {
    final localPort = config.localPort;
    final serverHost = config.serverHost;

    // Generate Shadowrocket .conf format
    final lines = [
      '[General]',
      'bypass-system = true',
      'skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local',
      'bypass-tun = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.88.99.0/24, 192.168.0.0/16, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 255.255.255.255/32',
      'dns-server = system',
      '',
      '[Proxy]',
      'LocalProxy = socks5, 127.0.0.1, $localPort',
      '',
      '[Rule]',
      'DOMAIN-SUFFIX,$serverHost,DIRECT',
      reverseGeo ? 'GEOIP,CN,LocalProxy' : 'GEOIP,CN,DIRECT',
      reverseGeo ? 'FINAL,DIRECT' : 'FINAL,LocalProxy',
    ];

    final content = lines.join('\n');

    if (base64Encode) {
      return base64.encode(utf8.encode(content));
    }
    return content;
  }
}
