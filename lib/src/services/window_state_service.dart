import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Remembers where the desktop window was last placed.
///
/// A saved frame is only reused when it still lands on a connected display.
/// Restoring blindly would strand the window off-screen after a monitor is
/// unplugged or the desktop is rearranged, with no way to drag it back.
class WindowStateService {
  WindowStateService._();

  static final WindowStateService instance = WindowStateService._();

  static const String _key = 'desktop_window_state';
  static const Duration _saveDelay = Duration(milliseconds: 500);

  /// How much of the window has to stay reachable for a frame to be reused.
  static const double _minimumVisibleWidth = 240;
  static const double _minimumVisibleHeight = 120;

  Timer? _saveTimer;
  bool _restoring = false;

  /// Applies the remembered frame. Call before the window is first shown.
  Future<void> restore() async {
    _restoring = true;
    try {
      final stored = await _read();
      if (stored == null) return;

      final frame = _frameOf(stored);
      if (frame != null && await _isReachable(frame)) {
        await windowManager.setBounds(frame);
      }
      if (stored['maximized'] == true) {
        await windowManager.maximize();
      }
    } catch (error) {
      debugPrint('Failed to restore the window frame: $error');
    } finally {
      _restoring = false;
    }
  }

  /// Records the current frame after the user stops dragging or resizing.
  void scheduleSave() {
    if (_restoring) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(saveNow()));
  }

  Future<void> saveNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_restoring) return;

    try {
      final stored = await _read() ?? <String, dynamic>{};
      final maximized = await windowManager.isMaximized();
      stored['maximized'] = maximized;
      // A maximized window reports the screen rect. Keep the last restored-down
      // frame instead, which is what unmaximizing should return to.
      if (!maximized) {
        final bounds = await windowManager.getBounds();
        stored['x'] = bounds.left;
        stored['y'] = bounds.top;
        stored['width'] = bounds.width;
        stored['height'] = bounds.height;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(stored));
    } catch (error) {
      debugPrint('Failed to save the window frame: $error');
    }
  }

  void dispose() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  Future<Map<String, dynamic>?> _read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Rect? _frameOf(Map<String, dynamic> stored) {
    final x = (stored['x'] as num?)?.toDouble();
    final y = (stored['y'] as num?)?.toDouble();
    final width = (stored['width'] as num?)?.toDouble();
    final height = (stored['height'] as num?)?.toDouble();
    if (x == null || y == null || width == null || height == null) return null;
    if (width < _minimumVisibleWidth || height < _minimumVisibleHeight) {
      return null;
    }
    return Rect.fromLTWH(x, y, width, height);
  }

  Future<bool> _isReachable(Rect frame) async {
    final List<Display> displays;
    try {
      displays = await screenRetriever.getAllDisplays();
    } catch (error) {
      debugPrint('Failed to enumerate displays: $error');
      return false;
    }

    for (final display in displays) {
      final origin = display.visiblePosition ?? Offset.zero;
      final size = display.visibleSize ?? display.size;
      final area = Rect.fromLTWH(
        origin.dx,
        origin.dy,
        size.width,
        size.height,
      );
      final overlap = area.intersect(frame);
      if (overlap.width >= _minimumVisibleWidth &&
          overlap.height >= _minimumVisibleHeight) {
        return true;
      }
    }
    return false;
  }
}
