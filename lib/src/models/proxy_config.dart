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
  bool allowLan;
  String? sessionKey;
  bool autoProxy;
  bool udpEnabled;
  bool udpDirectFallback;
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
    this.allowLan = false,
    this.sessionKey,
    this.autoProxy = true,
    this.udpEnabled = false,
    this.udpDirectFallback = true,
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
    'allowLan': allowLan,
    'sessionKey': sessionKey,
    'autoProxy': autoProxy,
    'udpEnabled': udpEnabled,
    'udpDirectFallback': udpDirectFallback,
    'tunEnabled': tunEnabled,
    'tunBypassProcesses': tunBypassProcesses,
    'androidVpnRoutingMode': androidVpnRoutingMode.wireName,
    'androidVpnPackages': androidVpnPackages,
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
        // Every field is parsed defensively: imported and hand-edited configs
        // routinely carry strings where numbers or booleans are expected, and a
        // single bad value must not make the whole configuration unreadable.
        serverHost: (json['serverHost'] ?? '').toString(),
        serverPort: _parsePort(json['serverPort'], 1081),
        localPort: _parsePort(json['localPort'], 1080),
        // LAN exposure is always opt-in, including imported legacy configs.
        allowLan: _parseBool(json['allowLan'], false),
        sessionKey: json['sessionKey']?.toString(),
        autoProxy: _parseBool(json['autoProxy'], true),
        // Imported configurations created by older versions keep the
        // historical behavior, where SOCKS5 UDP was always available.
        udpEnabled: _parseBool(json['udpEnabled'], true),
        // Preserve the Mihomo-style direct fallback for imported configs.
        udpDirectFallback: _parseBool(json['udpDirectFallback'], true),
        // TUN is opt-in so legacy configurations never start changing system
        // routes after an application upgrade.
        tunEnabled: _parseBool(json['tunEnabled'], false),
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
        reverseGeo: _parseBool(json['reverseGeo'], false),
        needCodecIps: json['needCodecIps']?.toString(),
        forceCodec: _parseBool(json['forceCodec'], false),
        setSystemProxy: _parseBool(json['setSystemProxy'], isDesktop),
      );

  ProxyConfigModel copyWith({
    String? serverHost,
    int? serverPort,
    int? localPort,
    bool? allowLan,
    String? sessionKey,
    bool? autoProxy,
    bool? udpEnabled,
    bool? udpDirectFallback,
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
    allowLan: allowLan ?? this.allowLan,
    sessionKey: sessionKey ?? this.sessionKey,
    autoProxy: autoProxy ?? this.autoProxy,
    udpEnabled: udpEnabled ?? this.udpEnabled,
    udpDirectFallback: udpDirectFallback ?? this.udpDirectFallback,
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
