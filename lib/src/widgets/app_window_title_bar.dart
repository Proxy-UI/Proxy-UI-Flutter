import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// A single Flutter-rendered title surface shared by all desktop platforms.
///
/// macOS keeps its native traffic-light buttons while Windows and Linux use
/// matching caption controls from `window_manager`. The remaining area is
/// draggable and visually continues the application's navigation surface.
class AppWindowTitleBar extends StatefulWidget implements PreferredSizeWidget {
  const AppWindowTitleBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.useNativeMacControls,
  });

  static const double height = 40;

  final String title;
  final List<Widget> actions;
  final bool? useNativeMacControls;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  State<AppWindowTitleBar> createState() => _AppWindowTitleBarState();
}

class _AppWindowTitleBarState extends State<AppWindowTitleBar>
    with WindowListener {
  bool _isMaximized = false;

  bool get _usesNativeMacControls =>
      widget.useNativeMacControls ??
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _refreshMaximizedState();
  }

  Future<void> _refreshMaximizedState() async {
    final isMaximized = await windowManager.isMaximized();
    if (mounted && isMaximized != _isMaximized) {
      setState(() => _isMaximized = isMaximized);
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: SizedBox(
        height: AppWindowTitleBar.height,
        child: Row(
          children: [
            if (_usesNativeMacControls) const SizedBox(width: 72),
            Expanded(
              child: DragToMoveArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/tray/tray_icon.png',
                        width: 18,
                        height: 18,
                        filterQuality: FilterQuality.medium,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ...widget.actions,
            if (!_usesNativeMacControls) ...[
              WindowCaptionButton.minimize(
                key: const Key('window-minimize'),
                brightness: theme.brightness,
                onPressed: () => windowManager.minimize(),
              ),
              _isMaximized
                  ? WindowCaptionButton.unmaximize(
                      key: const Key('window-restore'),
                      brightness: theme.brightness,
                      onPressed: () => windowManager.unmaximize(),
                    )
                  : WindowCaptionButton.maximize(
                      key: const Key('window-maximize'),
                      brightness: theme.brightness,
                      onPressed: () => windowManager.maximize(),
                    ),
              WindowCaptionButton.close(
                key: const Key('window-close'),
                brightness: theme.brightness,
                onPressed: () => windowManager.close(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
