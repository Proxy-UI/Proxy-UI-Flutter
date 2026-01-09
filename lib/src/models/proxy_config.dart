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

  ProxyConfigModel({
    this.serverHost = '',
    this.serverPort = 1081,
    this.localPort = 1080,
    this.sessionKey,
    this.autoProxy = true,
    this.reverseGeo = false,
    this.needCodecIps,
    this.forceCodec = false,
  });

  Map<String, dynamic> toJson() => {
        'serverHost': serverHost,
        'serverPort': serverPort,
        'localPort': localPort,
        'sessionKey': sessionKey,
        'autoProxy': autoProxy,
        'reverseGeo': reverseGeo,
        'needCodecIps': needCodecIps,
        'forceCodec': forceCodec,
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
  }) =>
      ProxyConfigModel(
        serverHost: serverHost ?? this.serverHost,
        serverPort: serverPort ?? this.serverPort,
        localPort: localPort ?? this.localPort,
        sessionKey: sessionKey ?? this.sessionKey,
        autoProxy: autoProxy ?? this.autoProxy,
        reverseGeo: reverseGeo ?? this.reverseGeo,
        needCodecIps: needCodecIps ?? this.needCodecIps,
        forceCodec: forceCodec ?? this.forceCodec,
      );
}
