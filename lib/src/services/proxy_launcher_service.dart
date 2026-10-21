import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/proxy_launcher.dart';
import 'build_capabilities.dart';
import 'claude_native_proxy.dart';
import 'windows_proxy_launcher_service.dart';

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

class ProxyLauncherService {
  static const channel = MethodChannel('proxy_ui/launchers');

  /// Desktop only: Android, iOS, Linux and the sandboxed Mac App Store build
  /// never show or start app proxies.
  static bool get isSupported => switch (defaultTargetPlatform) {
    TargetPlatform.windows => true,
    TargetPlatform.macOS => !BuildCapabilities.isMacAppStore,
    _ => false,
  };

  static final ProxyLauncherService _instance = Platform.isWindows
      ? WindowsProxyLauncherService()
      : ProxyLauncherService();
  static ProxyLauncherService forPlatform() => _instance;

  late final ClaudeNativeProxy _native = ClaudeNativeProxy(
    directory: Directory(
      Platform.isWindows
          ? '${Platform.environment['LOCALAPPDATA']}/CipherRelay/AppProxies'
          : '${Platform.environment['HOME']}/Library/Application Support/CipherRelay/AppProxies',
    ),
    library: Directory(
      Platform.isWindows
          ? '${Platform.environment['LOCALAPPDATA']}/Claude-3p/configLibrary'
          : '${Platform.environment['HOME']}/Library/Application Support/Claude-3p/configLibrary',
    ),
  );

  final _icons = <String, Future<Uint8List?>>{};

  Future<Object?> invokePlatform(String action, [Map<String, Object>? input]) =>
      channel.invokeMethod<Object?>(action, input);

  Future<void> initialize() => _native.initialize();

  Future<List<ProxyLauncher>> list() async {
    final entries = (await invokePlatform('list') as List?) ?? [];
    final native = await _native.configuration();
    return [
      ?native,
      ...entries
          .map((entry) => ProxyLauncher.fromJson(entry as Map))
          .where(
            (entry) =>
                native == null || entry.applicationId != native.applicationId,
          ),
    ];
  }

  Future<LauncherApplication?> chooseApplication() async {
    final result = await invokePlatform('chooseApplication') as Map?;
    return result == null ? null : LauncherApplication.fromJson(result);
  }

  Future<List<LauncherApplication>> discoverApplications() async =>
      ((await invokePlatform('discover') as List?) ?? [])
          .map((item) => LauncherApplication.fromJson(item as Map))
          .toList();

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

  /// Preserve an existing entry's port and rules, including after an
  /// installed app moves or updates.
  Future<ProxyLauncher> setUp(
    LauncherApplication app, {
    required List<ProxyLauncher> entries,
    required int port,
    required String suffix,
  }) => save(
    entries.where(app.hasLauncher).firstOrNull?.copyWith(mode: app.mode) ??
        ProxyLauncher(
          name: app.mode == LauncherMode.claudeNative
              ? app.name
              : '${app.name} $suffix',
          appPath: app.path,
          applicationId: app.id,
          mode: app.mode,
          port: port,
          bypassRules: ProxyLauncher.defaultBypassRules,
        ),
  );

  /// Application icons by path, fetched from the platform once per path,
  /// including while an earlier request for it is still running. Paths
  /// without an icon are left out; a failed request is retried next time.
  Future<Map<String, Uint8List>> icons(Iterable<String> paths) async {
    final missing = paths.where((path) => !_icons.containsKey(path)).toSet();
    if (missing.isNotEmpty) {
      final request = invokePlatform('icons', {'paths': missing.toList()});
      for (final path in missing) {
        _icons[path] = request.then(
          (found) => switch ((found as Map?)?[path]) {
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

  Future<ProxyLauncher> save(ProxyLauncher launcher) async {
    if (!launcher.isNative) {
      return ProxyLauncher.fromJson(
        await invokePlatform('save', launcher.toJson()) as Map,
      );
    }
    final current = await _currentNative(launcher);
    await invokePlatform('validateNative', current.toJson());
    final saved = await _native.save(current);
    // The native entry replaces generated Claude wrappers, while Codex keeps
    // its stable launcher path (and Dock entry). Trash is reversible.
    final legacy = (await invokePlatform('list') as List?) ?? [];
    for (final value in legacy) {
      final old = ProxyLauncher.fromJson(value as Map);
      if (old.applicationId == ClaudeNativeProxy.identity) {
        await invokePlatform('trash', {'id': old.id!});
      }
    }
    return saved;
  }

  Future<ProxyLauncher> _currentNative(ProxyLauncher launcher) async {
    final installed = (await discoverApplications())
        .where(
          (app) =>
              app.id == launcher.applicationId &&
              app.mode == LauncherMode.claudeNative,
        )
        .firstOrNull;
    return ProxyLauncher.fromJson({
      ...launcher.toJson(),
      'appPath': installed?.path ?? launcher.appPath,
      if (['Claude 代理启动器', 'Claude Proxy Launcher'].contains(launcher.name))
        'name': 'Claude',
    });
  }

  Future<void> open(ProxyLauncher launcher) async {
    await invokePlatform(
      launcher.isNative ? 'openNative' : 'open',
      launcher.isNative
          ? (await _currentNative(launcher)).toJson()
          : {'id': launcher.id!},
    );
  }

  Future<void> reveal(ProxyLauncher launcher) async {
    if (launcher.isNative) {
      await invokePlatform('revealNative', {'path': launcher.launcherPath!});
    } else {
      await invokePlatform('reveal', {'id': launcher.id!});
    }
  }

  Future<void> trash(ProxyLauncher launcher) async {
    if (launcher.isNative) {
      await _native.remove();
    } else {
      await invokePlatform('trash', {'id': launcher.id!});
    }
  }
}
