enum LauncherMode { chromium, environment, claudeNative }

class ProxyLauncher {
  const ProxyLauncher({
    this.id,
    required this.name,
    required this.appPath,
    required this.mode,
    required this.port,
    required this.bypassRules,
    this.launcherPath,
    this.applicationId,
    this.warning,
  });

  static const defaultBypassRules = ['*oa*', '.oa.com', '.woa.com'];
  final String? id;
  final String name;
  final String appPath;
  final LauncherMode mode;
  final int port;
  final List<String> bypassRules;
  final String? launcherPath;
  final String? applicationId;
  final String? warning;

  bool get isNative => mode == LauncherMode.claudeNative;

  ProxyLauncher withMode(LauncherMode value, {String? newId}) => ProxyLauncher(
    id: newId ?? id,
    name: name,
    appPath: appPath,
    mode: value,
    port: port,
    bypassRules: bypassRules,
    applicationId: applicationId,
    launcherPath: launcherPath,
  );

  factory ProxyLauncher.fromJson(Map<Object?, Object?> json) => ProxyLauncher(
    id: json['id'] as String?,
    name: json['name'] as String,
    appPath: json['appPath'] as String,
    mode: LauncherMode.values.byName(json['mode'] as String),
    port: json['port'] as int,
    bypassRules: (json['bypassRules'] as List).cast<String>(),
    launcherPath: json['launcherPath'] as String?,
    applicationId:
        (json['applicationId'] ?? json['bundleIdentifier']) as String?,
    warning: json['warning'] as String?,
  );

  Map<String, Object> toJson() => {
    'id': ?id,
    'name': name,
    'appPath': appPath,
    'mode': mode.name,
    'port': port,
    'bypassRules': bypassRules,
    'applicationId': ?applicationId,
  };

  static List<String> parseRules(String text) => text
      .split('\n')
      .map((line) => line.trim().toLowerCase())
      .where((line) => line.isNotEmpty)
      .toSet()
      .toList();

  static bool validRules(List<String> rules) =>
      rules.length <= 200 &&
      rules.every(
        (rule) =>
            rule.length <= 253 &&
            RegExp(r'^[a-z0-9*._\-\[\]:]+$').hasMatch(rule) &&
            rule != '.' &&
            !rule.contains('..') &&
            (!rule.contains(':') || rule == '::1' || rule == '[::1]'),
      );

  static bool validName(String value) =>
      value.trim().isNotEmpty &&
      value.length <= 80 &&
      !RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(value);
}
