import 'dart:convert';
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../ffi/native_proxy_operations.dart';
import '../models/proxy_launcher.dart';
import 'build_capabilities.dart';

class LauncherApplication {
  const LauncherApplication(this.name, this.path, this.mode, {this.id});
  final String name;
  final String path;
  final LauncherMode mode;
  final String? id;

  factory LauncherApplication.fromJson(Map<Object?, Object?> json) =>
      LauncherApplication(
        json['name'] as String,
        json['appPath'] as String,
        LauncherMode.values.byName(json['mode'] as String),
        id: json['applicationId'] as String?,
      );

  bool hasLauncher(ProxyLauncher launcher) =>
      (id != null && id == launcher.applicationId) ||
      (Platform.isWindows
          ? path.toLowerCase() == launcher.appPath.toLowerCase()
          : path == launcher.appPath);
}

/// App proxies live in the native core: detection, settings, Claude's routing
/// and the generated launchers. This class carries the page's requests there.
class ProxyLauncherService {
  /// macOS draws app icons with NSWorkspace, which the native core cannot.
  static const channel = MethodChannel('proxy_ui/launchers');

  /// Desktop only: Android, iOS, Linux and the sandboxed Mac App Store build
  /// never show or start app proxies.
  static bool get isSupported => switch (defaultTargetPlatform) {
    TargetPlatform.windows => true,
    TargetPlatform.macOS => !BuildCapabilities.isMacAppStore,
    _ => false,
  };

  static final ProxyLauncherService _instance = ProxyLauncherService();
  static ProxyLauncherService forPlatform() => _instance;

  final _icons = <String, Future<Uint8List?>>{};

  Future<Map<String, dynamic>> _request(
    String action, [
    Map<String, Object?> arguments = const {},
  ]) => NativeProxyOperations.shared.run(
    'app_proxies',
    arguments: {'action': action, ...arguments},
  );

  /// Restores Claude's routing before Claude is opened from its own icon.
  Future<void> initialize() => _request('initialize');

  Future<List<ProxyLauncher>> list() async => [
    for (final entry in (await _request('list'))['entries'] as List)
      ProxyLauncher.fromJson(entry as Map),
  ];

  Future<List<LauncherApplication>> discoverApplications() async => [
    for (final app in (await _request('discover'))['applications'] as List)
      LauncherApplication.fromJson(app as Map),
  ];

  Future<LauncherApplication?> chooseApplication() async {
    final file = await FileSelectorPlatform.instance.openFile(
      acceptedTypeGroups: [
        Platform.isMacOS
            ? const XTypeGroup(
                label: 'Applications',
                uniformTypeIdentifiers: ['com.apple.application-bundle'],
              )
            : const XTypeGroup(label: 'Applications', extensions: ['exe']),
      ],
      initialDirectory: Platform.isMacOS
          ? '/Applications'
          : Platform.environment['ProgramFiles'],
    );
    if (file == null) return null;
    final result = await _request('inspect', {'path': file.path});
    return LauncherApplication.fromJson(result['application'] as Map);
  }

  /// Detected apps still to set up: those without an entry, and Claude when
  /// it can move from a generated launcher to native settings.
  static List<LauncherApplication> pending(
    List<LauncherApplication> apps,
    List<ProxyLauncher> entries,
  ) => apps.where((app) {
    final previous = entries.where(app.hasLauncher).firstOrNull;
    return previous == null ||
        (app.mode == LauncherMode.claudeNative && !previous.isNative);
  }).toList();

  /// One click on a detected app; a previous entry keeps its port and rules.
  Future<ProxyLauncher> setUp(
    LauncherApplication app, {
    required int port,
    required String suffix,
  }) async => ProxyLauncher.fromJson(
    (await _request('set_up', {
          'path': app.path,
          'port': port,
          'suffix': suffix,
        }))['entry']
        as Map,
  );

  Future<ProxyLauncher> save(ProxyLauncher launcher) async =>
      ProxyLauncher.fromJson(
        (await _request('save', {'entry': launcher.toJson()}))['entry'] as Map,
      );

  Future<void> open(ProxyLauncher launcher) =>
      _request('open', {'entry': launcher.toJson()});

  Future<void> reveal(ProxyLauncher launcher) =>
      _request('reveal', {'entry': launcher.toJson()});

  Future<void> trash(ProxyLauncher launcher) =>
      _request('remove', {'entry': launcher.toJson()});

  /// Application icons by path, fetched once per path, including while an
  /// earlier request for it is still running. Paths without an icon are left
  /// out; a failed request is retried next time.
  Future<Map<String, Uint8List>> icons(Iterable<String> paths) async {
    final missing = paths.where((path) => !_icons.containsKey(path)).toSet();
    if (missing.isNotEmpty) {
      final request = fetchIcons(missing.toList());
      for (final path in missing) {
        _icons[path] = request.then(
          (found) => switch (found[path]) {
            final String encoded => base64Decode(encoded),
            _ => null,
          },
          onError: (Object _) {
            _icons.remove(path);
            return null;
          },
        );
      }
    }
    return {for (final path in paths) path: ?await _icons[path]};
  }

  /// Base64 PNG icons by path: AppKit on macOS, the shell icon on Windows.
  @protected
  Future<Map<Object?, Object?>> fetchIcons(List<String> paths) async =>
      Platform.isMacOS
      ? await channel.invokeMethod<Map<Object?, Object?>>('icons', {
              'paths': paths,
            }) ??
            const {}
      : (await _request('icons', {'paths': paths}))['icons'] as Map;
}
