import 'dart:io';

import '../services/build_capabilities.dart';

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
  bool tunFakeIp;
  String tunDnsServer;
  List<String> tunBypassProcesses;
  bool tunBypassWeGame;
  AndroidVpnRoutingMode androidVpnRoutingMode;
  List<String> androidVpnPackages;
  bool reverseGeo;
  bool secureTransport;
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
    bool? autoProxy,
    this.udpEnabled = false,
    bool? udpDirectFallback,
    this.tunEnabled = false,
    bool? tunFakeIp,
    this.tunDnsServer = '223.5.5.5',
    List<String> tunBypassProcesses = const [],
    bool? tunBypassWeGame,
    this.androidVpnRoutingMode = AndroidVpnRoutingMode.all,
    List<String> androidVpnPackages = const [],
    this.reverseGeo = false,
    this.secureTransport = false,
    bool? setSystemProxy,
  }) : autoProxy = autoProxy ?? !BuildCapabilities.isMacAppStore,
       // Preserve the hostname for upstream resolution. Advertising real AAAA
       // answers makes iOS prefer IPv6 even when the selected node lacks it.
       tunFakeIp = tunFakeIp ?? BuildCapabilities.isIOS,
       udpDirectFallback =
           udpDirectFallback ?? !BuildCapabilities.usesPacketTunnel,
       tunBypassProcesses = _normalizeProcessNames(tunBypassProcesses),
       tunBypassWeGame =
           tunBypassWeGame ?? suggestsWeGameBypass(tunBypassProcesses),
       androidVpnPackages = _normalizePackageNames(androidVpnPackages),
       setSystemProxy =
           setSystemProxy ??
           (isDesktop &&
               !BuildCapabilities
                   .usesPacketTunnel); // default true only for desktop

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
    'tunFakeIp': tunFakeIp,
    'tunDnsServer': tunDnsServer,
    'tunBypassProcesses': tunBypassProcesses,
    'tunBypassWeGame': tunBypassWeGame,
    'androidVpnRoutingMode': androidVpnRoutingMode.wireName,
    'androidVpnPackages': androidVpnPackages,
    'reverseGeo': reverseGeo,
    'secureTransport': secureTransport,
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

  static List<String> _parseStringList(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

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
        // UDP proxying is opt-in, including legacy and imported configs.
        udpEnabled: _parseBool(json['udpEnabled'], false),
        // Retain explicit legacy desktop fallback preferences.
        udpDirectFallback: _parseBool(
          json['udpDirectFallback'],
          !BuildCapabilities.usesPacketTunnel,
        ),
        // TUN is opt-in so legacy configurations never start changing system
        // routes after an application upgrade.
        tunEnabled: _parseBool(json['tunEnabled'], false),
        tunFakeIp: _parseBool(json['tunFakeIp'], BuildCapabilities.isIOS),
        tunDnsServer: (json['tunDnsServer'] ?? '223.5.5.5').toString().trim(),
        tunBypassProcesses: _parseStringList(json['tunBypassProcesses']),
        tunBypassWeGame: _parseBool(
          json['tunBypassWeGame'],
          suggestsWeGameBypass(_parseStringList(json['tunBypassProcesses'])),
        ),
        androidVpnRoutingMode: AndroidVpnRoutingMode.fromWireName(
          json['androidVpnRoutingMode'],
        ),
        androidVpnPackages: _parseStringList(json['androidVpnPackages']),
        reverseGeo: _parseBool(json['reverseGeo'], false),
        secureTransport: _parseBool(json['secureTransport'], false),
        setSystemProxy: _parseBool(json['setSystemProxy'], isDesktop),
      );

  ProxyConfigModel copyWith({
    String? serverHost,
    int? serverPort,
    int? localPort,
    bool? allowLan,
    String? sessionKey,
    bool clearSessionKey = false,
    bool? autoProxy,
    bool? udpEnabled,
    bool? udpDirectFallback,
    bool? tunEnabled,
    bool? tunFakeIp,
    String? tunDnsServer,
    List<String>? tunBypassProcesses,
    bool? tunBypassWeGame,
    AndroidVpnRoutingMode? androidVpnRoutingMode,
    List<String>? androidVpnPackages,
    bool? reverseGeo,
    bool? secureTransport,
    bool? setSystemProxy,
  }) => ProxyConfigModel(
    serverHost: serverHost ?? this.serverHost,
    serverPort: serverPort ?? this.serverPort,
    localPort: localPort ?? this.localPort,
    allowLan: allowLan ?? this.allowLan,
    sessionKey: clearSessionKey ? null : sessionKey ?? this.sessionKey,
    autoProxy: autoProxy ?? this.autoProxy,
    udpEnabled: udpEnabled ?? this.udpEnabled,
    udpDirectFallback: udpDirectFallback ?? this.udpDirectFallback,
    tunEnabled: tunEnabled ?? this.tunEnabled,
    tunFakeIp: tunFakeIp ?? this.tunFakeIp,
    tunDnsServer: tunDnsServer ?? this.tunDnsServer,
    tunBypassProcesses: tunBypassProcesses ?? this.tunBypassProcesses,
    tunBypassWeGame: tunBypassWeGame ?? this.tunBypassWeGame,
    androidVpnRoutingMode: androidVpnRoutingMode ?? this.androidVpnRoutingMode,
    androidVpnPackages: androidVpnPackages ?? this.androidVpnPackages,
    reverseGeo: reverseGeo ?? this.reverseGeo,
    secureTransport: secureTransport ?? this.secureTransport,
    setSystemProxy: setSystemProxy ?? this.setSystemProxy,
  );

  /// Keep the saved executable selection separate from the native family rule.
  List<String> get effectiveTunBypassProcesses => [
    ...tunBypassProcesses,
    if (Platform.isWindows && tunBypassWeGame) '@group:wegame',
  ];

  /// Upgrade a previous explicit LOL/WeGame exclusion to the complete family.
  /// A saved false value remains authoritative after the user turns it off.
  static bool suggestsWeGameBypass(Iterable<String> names) =>
      _normalizeProcessNames(names).any(
        (name) => const {
          'league of legends',
          'leagueclient',
          'leagueclientux',
          'leagueclientuxrender',
          'wegame',
          'wegame_env',
          'tgp',
        }.contains(name),
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
