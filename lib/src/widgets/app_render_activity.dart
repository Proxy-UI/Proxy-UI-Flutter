import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import '../services/window_state_service.dart';

/// Decorative UI work follows visibility, independently of the VPN lifetime.
class AppRenderActivity extends StatefulWidget {
  const AppRenderActivity({super.key, required this.child});

  final Widget child;

  @override
  State<AppRenderActivity> createState() => _AppRenderActivityState();
}

class _AppRenderActivityState extends State<AppRenderActivity>
    with WidgetsBindingObserver, WindowListener {
  bool _visible = true;
  bool _foreground = true;

  late final _desktop = switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (_desktop) windowManager.addListener(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _foreground) setState(() => _foreground = foreground);
  }

  void _setVisible(bool visible) {
    if (_visible != visible) setState(() => _visible = visible);
  }

  @override
  void onWindowBlur() => _setVisible(false);
  @override
  void onWindowMinimize() => _setVisible(false);
  @override
  void onWindowFocus() => _setVisible(true);
  @override
  void onWindowRestore() => _setVisible(true);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_desktop) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_desktop) {
      return TickerMode(enabled: _foreground, child: widget.child);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: WindowStateService.instance.visible,
      child: widget.child,
      builder: (context, shown, child) =>
          TickerMode(enabled: _foreground && _visible && shown, child: child!),
    );
  }
}
