import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../ffi/proxy_service.dart';

typedef LogDirectoryProvider = Future<Directory> Function();
typedef LogDirectoryOpener = Future<void> Function(String path);

/// Persists native log entries for desktop builds without blocking the UI.
class DesktopLogService {
  DesktopLogService({
    bool? enabled,
    this.retention = const Duration(days: 3),
    LogDirectoryProvider? directoryProvider,
    LogDirectoryOpener? directoryOpener,
    DateTime Function()? clock,
  }) : enabled = enabled ?? _isDesktop,
       _directoryProvider = directoryProvider ?? _defaultDirectoryProvider,
       _directoryOpener = directoryOpener ?? _defaultDirectoryOpener,
       _clock = clock ?? DateTime.now;

  static const String filePrefix = 'proxy-ui';

  final bool enabled;
  final Duration retention;
  final LogDirectoryProvider _directoryProvider;
  final LogDirectoryOpener _directoryOpener;
  final DateTime Function() _clock;

  Future<void> _pendingWrite = Future<void>.value();
  Future<Directory>? _logDirectory;
  IOSink? _sink;
  String? _openHour;
  String? _lastCleanupHour;
  Future<void>? _cleanupOperation;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  static Future<Directory> _defaultDirectoryProvider() async {
    final applicationDirectory = await getApplicationSupportDirectory();
    return Directory(
      '${applicationDirectory.path}${Platform.pathSeparator}logs',
    );
  }

  static Future<void> _defaultDirectoryOpener(String path) async {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [
        path,
      ], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [path], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isLinux) {
      await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
      return;
    }
    throw UnsupportedError('Log folders are only available on desktop');
  }

  /// Queues one entry for ordered disk persistence.
  Future<void> write(LogEntry entry) {
    if (!enabled || _disposed) return Future<void>.value();

    final operation = _pendingWrite.then((_) => _writeEntry(entry));
    _pendingWrite = operation.onError((_, _) {});
    return operation;
  }

  /// Creates the desktop log directory and applies retention at app startup.
  Future<void> initialize() async {
    if (!enabled || _disposed) return;
    final directory = await _ensureLogDirectory();
    await _cleanupIfNeeded(directory, _clock());
  }

  /// Creates and opens the log directory in the platform file manager.
  Future<void> openLogDirectory() async {
    if (!enabled) {
      throw UnsupportedError('Log folders are only available on desktop');
    }
    final directory = await _ensureLogDirectory();
    await _cleanupIfNeeded(directory, _clock());
    await _directoryOpener(directory.path);
  }

  Future<void> _writeEntry(LogEntry entry) async {
    final localTimestamp = entry.timestamp.toLocal();
    final hour = _hourKey(localTimestamp);
    final directory = await _ensureLogDirectory();

    if (_sink != null && _openHour != hour) {
      await _sink!.close();
      _sink = null;
      _openHour = null;
    }

    await _cleanupIfNeeded(directory, _clock());

    if (_sink == null) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}'
        '$filePrefix-$hour.log',
      );
      _sink = file.openWrite(mode: FileMode.append);
      _openHour = hour;
    }

    _sink!.writeln(
      '${_formatTimestamp(localTimestamp)} '
      '[${entry.levelName}] ${entry.message}',
    );
    await _sink!.flush();
  }

  Future<Directory> _ensureLogDirectory() async {
    final cached = _logDirectory;
    if (cached != null) return cached;

    final operation = () async {
      final directory = await _directoryProvider();
      await directory.create(recursive: true);
      return directory;
    }();
    _logDirectory = operation;
    try {
      return await operation;
    } catch (_) {
      if (identical(_logDirectory, operation)) _logDirectory = null;
      rethrow;
    }
  }

  Future<void> _removeExpiredFiles(Directory directory, DateTime now) async {
    final localNow = now.toLocal();
    final cutoff = localNow.subtract(retention);
    final cutoffHour = DateTime(
      cutoff.year,
      cutoff.month,
      cutoff.day,
      cutoff.hour,
    );
    final pattern = RegExp(
      '^$filePrefix-(\\d{4})-(\\d{2})-(\\d{2})-(\\d{2})\\.log\$',
    );

    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name == '$filePrefix-$_openHour.log') continue;
      final match = pattern.firstMatch(name);
      if (match == null) continue;

      final fileHour = _parseHour(match);
      if (fileHour != null && fileHour.isBefore(cutoffHour)) {
        await entity.delete();
      }
    }
    _lastCleanupHour = _hourKey(localNow);
  }

  Future<void> _cleanupIfNeeded(Directory directory, DateTime now) async {
    final cleanupHour = _hourKey(now.toLocal());
    if (_lastCleanupHour == cleanupHour) return;

    final running = _cleanupOperation;
    if (running != null) {
      await running;
      return _cleanupIfNeeded(directory, now);
    }

    final operation = _removeExpiredFiles(directory, now);
    _cleanupOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_cleanupOperation, operation)) _cleanupOperation = null;
    }
  }

  DateTime? _parseHour(RegExpMatch match) {
    try {
      final value = DateTime(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
      );
      if (_hourKey(value) !=
          '${match.group(1)}-${match.group(2)}-'
              '${match.group(3)}-${match.group(4)}') {
        return null;
      }
      return value;
    } on FormatException {
      return null;
    }
  }

  static String _hourKey(DateTime value) {
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}-'
        '${value.hour.toString().padLeft(2, '0')}';
  }

  static String _formatTimestamp(DateTime value) {
    final offset = value.timeZoneOffset;
    final offsetSign = offset.isNegative ? '-' : '+';
    final absoluteOffset = offset.abs();
    final offsetHours = absoluteOffset.inHours.toString().padLeft(2, '0');
    final offsetMinutes = (absoluteOffset.inMinutes % 60).toString().padLeft(
      2,
      '0',
    );
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}T'
        '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}.'
        '${value.millisecond.toString().padLeft(3, '0')}'
        '$offsetSign$offsetHours:$offsetMinutes';
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;

    _disposed = true;
    final operation = _pendingWrite.then((_) async {
      await _sink?.close();
      _sink = null;
      _openHour = null;
    });
    _disposeFuture = operation;
    return operation;
  }
}
