import 'dart:io';

enum AndroidVpnRoutingMode {
  all('all'),
  exclude('exclude'),
  include('include');

  final String wireName;

  const AndroidVpnRoutingMode(this.wireName);

  static AndroidVpnRoutingMode fromWireName(Object? value) {
    return values.firstWhere(
      (mode) => mode.wireName == value,
      orElse: () => AndroidVpnRoutingMode.all,
    );
  }
}

/// Proxy configuration model.
class ProxyConfigModel {
  String serverHost;
  int serverPort;
  int localPort;
  String? sessionKey;
  bool autoProxy;
  bool udpEnabled;
  bool tunEnabled;
  List<String> tunBypassProcesses;
  AndroidVpnRoutingMode androidVpnRoutingMode;
  List<String> androidVpnPackages;
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
    this.localPort = 10801,
    this.sessionKey,
    this.autoProxy = true,
    this.udpEnabled = false,
    this.tunEnabled = false,
    List<String> tunBypassProcesses = const [],
    this.androidVpnRoutingMode = AndroidVpnRoutingMode.all,
    List<String> androidVpnPackages = const [],
    this.reverseGeo = false,
    this.needCodecIps,
    this.forceCodec = false,
    bool? setSystemProxy,
  }) : tunBypassProcesses = _normalizeProcessNames(tunBypassProcesses),
       androidVpnPackages = _normalizePackageNames(androidVpnPackages),
       setSystemProxy =
           setSystemProxy ?? isDesktop; // default true only for desktop

  Map<String, dynamic> toJson() => {
    'serverHost': serverHost,
    'serverPort': serverPort,
    'localPort': localPort,
    'sessionKey': sessionKey,
    'autoProxy': autoProxy,
    'udpEnabled': udpEnabled,
    'tunEnabled': tunEnabled,
    'tunBypassProcesses': tunBypassProcesses,
    'androidVpnRoutingMode': androidVpnRoutingMode.wireName,
    'androidVpnPackages': androidVpnPackages,
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
        // Imported configurations created by older versions keep the
        // historical behavior, where SOCKS5 UDP was always available.
        udpEnabled: json['udpEnabled'] ?? true,
        // TUN is opt-in so legacy configurations never start changing system
        // routes after an application upgrade.
        tunEnabled: json['tunEnabled'] ?? false,
        tunBypassProcesses:
            (json['tunBypassProcesses'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            const [],
        androidVpnRoutingMode: AndroidVpnRoutingMode.fromWireName(
          json['androidVpnRoutingMode'],
        ),
        androidVpnPackages:
            (json['androidVpnPackages'] as List<dynamic>?)
                ?.whereType<String>()
                .toList() ??
            const [],
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
    bool? udpEnabled,
    bool? tunEnabled,
    List<String>? tunBypassProcesses,
    AndroidVpnRoutingMode? androidVpnRoutingMode,
    List<String>? androidVpnPackages,
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
    udpEnabled: udpEnabled ?? this.udpEnabled,
    tunEnabled: tunEnabled ?? this.tunEnabled,
    tunBypassProcesses: tunBypassProcesses ?? this.tunBypassProcesses,
    androidVpnRoutingMode: androidVpnRoutingMode ?? this.androidVpnRoutingMode,
    androidVpnPackages: androidVpnPackages ?? this.androidVpnPackages,
    reverseGeo: reverseGeo ?? this.reverseGeo,
    needCodecIps: needCodecIps ?? this.needCodecIps,
    forceCodec: forceCodec ?? this.forceCodec,
    setSystemProxy: setSystemProxy ?? this.setSystemProxy,
  );
}

List<String> _normalizePackageNames(Iterable<String> packages) {
  final normalized = packages
      .map((packageName) => packageName.trim())
      .where((packageName) => packageName.isNotEmpty)
      .toSet()
      .toList();
  normalized.sort();
  return normalized;
}

List<String> _normalizeProcessNames(Iterable<String> names) {
  final normalized = names
      .map((name) => name.trim().toLowerCase())
      .map(
        (name) =>
            name.endsWith('.exe') ? name.substring(0, name.length - 4) : name,
      )
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList();
  normalized.sort();
  return normalized;
}
