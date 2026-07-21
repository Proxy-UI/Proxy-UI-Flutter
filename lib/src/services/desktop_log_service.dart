import 'dart:async';
import 'dart:collection';
import 'dart:convert';
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
    this.maxPendingEntries = 4096,
    this.maxFileBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 512 * 1024 * 1024,
    this.batchSize = 256,
    LogDirectoryProvider? directoryProvider,
    LogDirectoryOpener? directoryOpener,
    DateTime Function()? clock,
  }) : assert(maxPendingEntries > 0),
       assert(maxFileBytes > 0),
       assert(maxTotalBytes > 0),
       assert(batchSize > 0),
       enabled = enabled ?? _isDesktop,
       _directoryProvider = directoryProvider ?? _defaultDirectoryProvider,
       _directoryOpener = directoryOpener ?? _defaultDirectoryOpener,
       _clock = clock ?? DateTime.now;

  static const String filePrefix = 'proxy-ui';

  final bool enabled;
  final Duration retention;
  final int maxPendingEntries;
  final int maxFileBytes;
  final int maxTotalBytes;
  final int batchSize;
  final LogDirectoryProvider _directoryProvider;
  final LogDirectoryOpener _directoryOpener;
  final DateTime Function() _clock;

  final ListQueue<_PendingLogWrite> _pendingWrites =
      ListQueue<_PendingLogWrite>();
  Completer<void>? _drainCompleter;
  int _droppedPendingEntries = 0;
  Future<Directory>? _logDirectory;
  IOSink? _sink;
  String? _openHour;
  int _openFileBytes = 0;
  bool _fileLimitNoticeWritten = false;
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
    if (_pendingWrites.length >= maxPendingEntries) {
      _droppedPendingEntries++;
      return Future<void>.value();
    }

    final pending = _PendingLogWrite(entry);
    _pendingWrites.addLast(pending);
    _ensureDrain();
    return pending.completer.future;
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

  void _ensureDrain() {
    if (_drainCompleter != null || _pendingWrites.isEmpty) return;
    final completer = Completer<void>();
    _drainCompleter = completer;
    scheduleMicrotask(() async {
      try {
        await _drainPendingWrites();
      } finally {
        if (!completer.isCompleted) completer.complete();
        if (identical(_drainCompleter, completer)) {
          _drainCompleter = null;
        }
        if (_pendingWrites.isNotEmpty) _ensureDrain();
      }
    });
  }

  Future<void> _drainPendingWrites() async {
    while (_pendingWrites.isNotEmpty) {
      final batch = <_PendingLogWrite>[];
      while (batch.length < batchSize && _pendingWrites.isNotEmpty) {
        batch.add(_pendingWrites.removeFirst());
      }
      final dropped = _droppedPendingEntries;
      _droppedPendingEntries = 0;
      try {
        await _writeBatch(batch.map((pending) => pending.entry), dropped);
        for (final pending in batch) {
          if (!pending.completer.isCompleted) pending.completer.complete();
        }
      } catch (error, stackTrace) {
        for (final pending in batch) {
          if (!pending.completer.isCompleted) {
            pending.completer.completeError(error, stackTrace);
          }
        }
      }
      // Let UI and network events run between disk batches.
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _writeBatch(Iterable<LogEntry> entries, int dropped) async {
    final directory = await _ensureLogDirectory();
    await _cleanupIfNeeded(directory, _clock());

    final batch = entries.toList(growable: true);
    if (dropped > 0) {
      batch.insert(
        0,
        LogEntry(
          level: 3,
          message:
              'Desktop log queue dropped $dropped entries to protect memory '
              'while disk persistence was behind.',
          timestamp: batch.isEmpty ? _clock() : batch.first.timestamp,
        ),
      );
    }

    for (final entry in batch) {
      final localTimestamp = entry.timestamp.toLocal();
      final hour = _hourKey(localTimestamp);
      await _openSink(directory, hour);
      _writeLine(entry, localTimestamp);
    }
    await _sink?.flush();
  }

  Future<void> _openSink(Directory directory, String hour) async {
    if (_sink != null && _openHour == hour) return;
    if (_sink != null) {
      await _sink!.close();
    }

    final file = File(
      '${directory.path}${Platform.pathSeparator}$filePrefix-$hour.log',
    );
    _openFileBytes = await file.exists() ? await file.length() : 0;
    _fileLimitNoticeWritten = _openFileBytes >= maxFileBytes;
    _sink = file.openWrite(mode: FileMode.append);
    _openHour = hour;
  }

  void _writeLine(LogEntry entry, DateTime localTimestamp) {
    final line = utf8.encode(
      '${_formatTimestamp(localTimestamp)} '
      '[${entry.levelName}] ${entry.message}\n',
    );
    if (_openFileBytes + line.length <= maxFileBytes) {
      _sink!.add(line);
      _openFileBytes += line.length;
      return;
    }

    if (_fileLimitNoticeWritten) return;
    _fileLimitNoticeWritten = true;
    final marker = utf8.encode(
      '${_formatTimestamp(localTimestamp)} [WARN] '
      'Hourly log size limit reached; further entries are omitted.\n',
    );
    _sink!.add(marker);
    _openFileBytes += marker.length;
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

    final retained = <({File file, DateTime hour, int bytes})>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = pattern.firstMatch(name);
      if (match == null) continue;

      final fileHour = _parseHour(match);
      if (fileHour == null) continue;
      if (name != '$filePrefix-$_openHour.log' &&
          fileHour.isBefore(cutoffHour)) {
        await entity.delete();
        continue;
      }
      retained.add((
        file: entity,
        hour: fileHour,
        bytes: await entity.length(),
      ));
    }

    var totalBytes = retained.fold<int>(
      0,
      (total, entry) => total + entry.bytes,
    );
    retained.sort((left, right) => left.hour.compareTo(right.hour));
    for (final entry in retained) {
      if (totalBytes <= maxTotalBytes) break;
      if (entry.file.uri.pathSegments.last == '$filePrefix-$_openHour.log') {
        continue;
      }
      await entry.file.delete();
      totalBytes -= entry.bytes;
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
    final operation = () async {
      while (_pendingWrites.isNotEmpty || _drainCompleter != null) {
        _ensureDrain();
        final drain = _drainCompleter;
        if (drain == null) break;
        await drain.future;
      }
      await _sink?.close();
      _sink = null;
      _openHour = null;
    }();
    _disposeFuture = operation;
    return operation;
  }
}

class _PendingLogWrite {
  _PendingLogWrite(this.entry);

  final LogEntry entry;
  final Completer<void> completer = Completer<void>();
}
