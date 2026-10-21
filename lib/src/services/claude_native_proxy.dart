import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../models/proxy_launcher.dart';
import 'app_proxy_router.dart';

/// Owns only Claude's two proxy keys. Other settings (including credentials,
/// inference provider and login mode) are read/merged, never stored in our state.
class ClaudeNativeProxy {
  ClaudeNativeProxy({required this.directory, required this.library});

  final Directory directory;
  final Directory library;
  AppProxyRouter? _router;
  Map<String, dynamic>? _state;
  bool _loaded = false;
  String? _warning;
  static const identity = 'com.anthropic.claudefordesktop';
  static const id = 'claude-native';
  static const _keys = ['egressProxyUrl', 'egressProxyPacUrl'];
  File get _stateFile => File('${directory.path}/claude-native.json');

  Future<void> initialize() async {
    if (_loaded) return;
    _state = await _read(_stateFile, optional: true);
    _loaded = true;
    if (_state != null) {
      final configuration = ProxyLauncher.fromJson(_state!['configuration']);
      final router = AppProxyRouter(configuration);
      try {
        await router.start(_state!['routerPort'] as int);
        _router = router;
      } catch (error) {
        _warning = error.toString();
      }
    }
  }

  Future<ProxyLauncher?> configuration() async {
    await initialize();
    return _state == null
        ? null
        : ProxyLauncher.fromJson({
            ..._state!['configuration'] as Map,
            'warning': _warning,
          });
  }

  Future<File> _activeFile() async {
    final metaFile = File('${library.path}/_meta.json');
    var meta = await _read(metaFile, optional: true);
    if (meta?['hybridPointer'] != null) {
      throw StateError(
        'Claude uses a managed deployment; its local proxy settings cannot be applied.',
      );
    }
    if (meta == null) {
      final random = Random.secure();
      final bytes = List.generate(16, (_) => random.nextInt(256));
      bytes[6] = (bytes[6] & 15) | 64;
      bytes[8] = (bytes[8] & 63) | 128;
      final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final uuid =
          '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
          '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
      await _write(File('${library.path}/$uuid.json'), {});
      meta = {
        'appliedId': uuid,
        'entries': [
          {'id': uuid, 'name': 'Default'},
        ],
      };
      await _write(metaFile, meta);
    }
    final appliedId = meta['appliedId'];
    if (appliedId is! String ||
        !RegExp(r'^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
            .hasMatch(appliedId)) {
      throw StateError('Claude has no valid active local configuration.');
    }
    return File('${library.path}/$appliedId.json');
  }

  Future<ProxyLauncher> save(ProxyLauncher input) async {
    await initialize();
    if (input.applicationId != identity ||
        !input.isNative ||
        input.port < 1 ||
        input.port > 65535 ||
        !ProxyLauncher.validName(input.name) ||
        !ProxyLauncher.validRules(input.bypassRules)) {
      throw const FormatException('Invalid Claude proxy settings.');
    }
    final file = await _activeFile();
    final current = (await _read(file))!;
    if (_state != null) {
      if (_state!['configFile'] != file.path ||
          !_sameKeys(current, _state!['applied'] as Map)) {
        throw StateError(
          'Claude proxy settings changed outside CipherRelay. Remove this entry first; external changes will be preserved.',
        );
      }
    }
    final previous = _state;
    final router = _router ?? AppProxyRouter(input);
    if (_router == null) await router.start();
    if (router.port == input.port) {
      if (_router == null) await router.close();
      throw StateError(
        'The upstream proxy port conflicts with the app routing port.',
      );
    }
    final applied = {
      'egressProxyUrl': 'http://127.0.0.1:${router.port}',
      'egressProxyPacUrl': null,
    };
    final saved = ProxyLauncher.fromJson({
      ...input.toJson(),
      'id': id,
      'launcherPath': file.path,
    });
    final state = <String, dynamic>{
      'schemaVersion': 1,
      'configuration': {...saved.toJson(), 'launcherPath': file.path},
      'routerPort': router.port,
      'configFile': file.path,
      'original':
          previous?['original'] ?? {for (final key in _keys) key: current[key]},
      'applied': applied,
    };
    try {
      // Persist the restoration record before touching another app's settings.
      await _write(_stateFile, state);
      // Re-read just before writing so unrelated changes are preserved.
      final latest = (await _read(file))!;
      if (!_sameKeys(latest, {for (final key in _keys) key: current[key]})) {
        throw StateError(
          'Claude proxy settings changed while saving. Try again.',
        );
      }
      _merge(latest, applied);
      await _write(file, latest);
    } catch (_) {
      if (previous == null) {
        if (await _stateFile.exists()) await _stateFile.delete();
        await router.close();
      } else {
        await _write(_stateFile, previous);
      }
      rethrow;
    }
    router.configuration = saved;
    _router = router;
    _state = state;
    _warning = null;
    return saved;
  }

  Future<void> remove() async {
    await initialize();
    final state = _state;
    if (state == null) return;
    // Never restore over a user's later edits or change which profile is active.
    final file = File(state['configFile'] as String);
    if (file.parent.absolute.path != library.absolute.path) {
      throw StateError('Invalid native configuration path.');
    }
    final current = await _read(file, optional: true);
    if (current != null && _sameKeys(current, state['applied'] as Map)) {
      // PAC takes precedence over the fixed URL; restore these as a group.
      // Restoring just an old PAC could override a user's newly changed URL.
      _merge(current, state['original'] as Map);
      await _write(file, current);
    }
    await _stateFile.delete();
    await close();
    _state = null;
    _warning = null;
  }

  static bool _sameKeys(Map current, Map expected) =>
      _keys.every((key) => current[key] == expected[key]);

  static void _merge(Map<String, dynamic> current, Map values) {
    for (final key in values.keys) {
      if (values[key] == null) {
        current.remove(key);
      } else {
        current[key as String] = values[key];
      }
    }
  }

  static Future<Map<String, dynamic>?> _read(
    File file, {
    bool optional = false,
  }) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && optional) return null;
    if (type != FileSystemEntityType.file ||
        await FileSystemEntity.isLink(file.parent.path)) {
      throw StateError('Expected a regular configuration file: ${file.path}');
    }
    Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on FormatException {
      // JSON parser exceptions include source excerpts, potentially credentials.
      throw FormatException(
        'Invalid JSON in ${file.path}. Existing settings were preserved.',
      );
    }
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Configuration must be a JSON object.');
    }
    return value;
  }

  static Future<void> _write(File file, Map value) async {
    if (await FileSystemEntity.isLink(file.parent.path) ||
        await FileSystemEntity.isLink(file.path)) {
      throw StateError('Configuration paths cannot be symbolic links.');
    }
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.cipherrelay-${Random.secure().nextInt(1 << 32)}',
    );
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
        flush: true,
      );
      if (Platform.isMacOS || Platform.isLinux) {
        final result = await Process.run('/bin/chmod', ['600', temporary.path]);
        if (result.exitCode != 0) {
          throw FileSystemException(
            'Could not protect configuration',
            temporary.path,
          );
        }
      }
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> close() async {
    await _router?.close();
    _router = null;
    _loaded = false;
  }
}
