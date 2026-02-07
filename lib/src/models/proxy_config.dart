import 'dart:io';

/// Proxy configuration model.
class ProxyConfigModel {
  String serverHost;
  int serverPort;
  int localPort;
  String? sessionKey;
  bool autoProxy;
  bool reverseGeo;
  String? needCodecIps;
  bool forceCodec;
  bool setSystemProxy; // desktop only

  /// Check if current platform is desktop
  static bool get isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  ProxyConfigModel({
    this.serverHost = '',
    this.serverPort = 1081,
    this.localPort = 1080,
    this.sessionKey,
    this.autoProxy = true,
    this.reverseGeo = false,
    this.needCodecIps,
    this.forceCodec = false,
    bool? setSystemProxy,
  }) : setSystemProxy =
           setSystemProxy ?? isDesktop; // default true only for desktop

  Map<String, dynamic> toJson() => {
    'serverHost': serverHost,
    'serverPort': serverPort,
    'localPort': localPort,
    'sessionKey': sessionKey,
    'autoProxy': autoProxy,
    'reverseGeo': reverseGeo,
    'needCodecIps': needCodecIps,
    'forceCodec': forceCodec,
    'setSystemProxy': setSystemProxy,
  };

  static int _parsePort(dynamic value, int fallback) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return fallback;
    }
    return parsed;
  }

  static bool _parseBool(dynamic value, bool fallback) {
    if (value is bool) {
      return value;
    }
    if (value is String) {
      if (value.toLowerCase() == 'true') return true;
      if (value.toLowerCase() == 'false') return false;
    }
    return fallback;
  }

  factory ProxyConfigModel.fromJson(Map<String, dynamic> json) =>
      ProxyConfigModel(
        serverHost: (json['serverHost'] ?? '').toString(),
        serverPort: _parsePort(json['serverPort'], 1081),
        localPort: _parsePort(json['localPort'], 1080),
        sessionKey: json['sessionKey']?.toString(),
        autoProxy: _parseBool(json['autoProxy'], true),
        reverseGeo: _parseBool(json['reverseGeo'], false),
        needCodecIps: json['needCodecIps']?.toString(),
        forceCodec: _parseBool(json['forceCodec'], false),
        setSystemProxy: _parseBool(json['setSystemProxy'], isDesktop),
      );

  ProxyConfigModel copyWith({
    String? serverHost,
    int? serverPort,
    int? localPort,
    String? sessionKey,
    bool? autoProxy,
    bool? reverseGeo,
    String? needCodecIps,
    bool? forceCodec,
    bool? setSystemProxy,
  }) => ProxyConfigModel(
    serverHost: serverHost ?? this.serverHost,
    serverPort: serverPort ?? this.serverPort,
    localPort: localPort ?? this.localPort,
    sessionKey: sessionKey ?? this.sessionKey,
    autoProxy: autoProxy ?? this.autoProxy,
    reverseGeo: reverseGeo ?? this.reverseGeo,
    needCodecIps: needCodecIps ?? this.needCodecIps,
    forceCodec: forceCodec ?? this.forceCodec,
    setSystemProxy: setSystemProxy ?? this.setSystemProxy,
  );
}
