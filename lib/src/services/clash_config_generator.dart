import '../models/proxy_config.dart';

class ClashConfigGenerator {
  static String generate(ProxyConfigModel config) {
    final localPort = config.localPort;

    return '''
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info

proxies:
  - name: "LocalProxy"
    type: socks5
    server: 127.0.0.1
    port: $localPort
    udp: false

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - LocalProxy
      - DIRECT

rules:
  - DST-PORT,$localPort,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT
  - GEOIP,LAN,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
''';
  }
}
