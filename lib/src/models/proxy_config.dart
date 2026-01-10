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
  }) : setSystemProxy = setSystemProxy ?? isDesktop; // default true only for desktop

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

  factory ProxyConfigModel.fromJson(Map<String, dynamic> json) =>
      ProxyConfigModel(
        serverHost: json['serverHost'] ?? '',
        serverPort: json['serverPort'] ?? 1081,
        localPort: json['localPort'] ?? 1080,
        sessionKey: json['sessionKey'],
        autoProxy: json['autoProxy'] ?? true,
        reverseGeo: json['reverseGeo'] ?? false,
        needCodecIps: json['needCodecIps'],
        forceCodec: json['forceCodec'] ?? false,
        setSystemProxy: json['setSystemProxy'] ?? isDesktop,
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
