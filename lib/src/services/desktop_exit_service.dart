import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Separates closing the desktop window from shutting down the proxy.
class DesktopExitService with WindowListener, WidgetsBindingObserver {
  DesktopExitService({
    required this.platform,
    required this.hideToTray,
    required this.prepareToQuit,
  });

  final TargetPlatform platform;
  final AsyncCallback hideToTray;
  final AsyncCallback prepareToQuit;

  @override
  Future<void> onWindowClose() => hideToTray();

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (platform == TargetPlatform.windows) {
      // Flutter handles the last window's WM_CLOSE before window_manager can
      // apply setPreventClose. Accepting this request stops the proxy before
      // the plugin receives the re-dispatched close and hides the window.
      // Cancel here and hide ourselves: cancellation prevents that re-dispatch.
      // The tray's explicit Quit path performs teardown and exits separately.
      try {
        await onWindowClose();
      } catch (error) {
        // A shell failure must not turn a window-close request into app exit.
        debugPrint('Failed to hide the window on close: $error');
      }
      return AppExitResponse.cancel;
    }

    // macOS's red close button reaches onWindowClose, while Cmd-Q / Dock Quit
    // reaches this callback. Keep awaiting teardown for actual app termination.
    await prepareToQuit();
    return AppExitResponse.exit;
  }
}
