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
    required this.shouldRetryQuit,
    required this.retryQuit,
  });

  final TargetPlatform platform;
  final AsyncCallback hideToTray;
  final AsyncCallback prepareToQuit;
  final bool Function() shouldRetryQuit;
  final AsyncCallback retryQuit;

  @override
  Future<void> onWindowClose() =>
      shouldRetryQuit() ? retryQuit() : hideToTray();

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (platform == TargetPlatform.windows) {
      // Flutter handles the last window's WM_CLOSE before window_manager can
      // apply setPreventClose. Accepting this request stops the proxy before
      // the plugin receives the re-dispatched close and hides the window.
      // Cancel here and hide ourselves: cancellation prevents that re-dispatch.
      // The tray's explicit Quit path performs teardown and exits separately.
      // After tray teardown starts, the window retries that same explicit quit
      // path instead of hiding behind an icon that can no longer raise it.
      try {
        await onWindowClose();
      } catch (error) {
        // A shell failure must not turn a window-close request into app exit.
        debugPrint('Window close failed; keeping the app open: $error');
      }
      return AppExitResponse.cancel;
    }

    // macOS's red close button reaches onWindowClose, while Cmd-Q / Dock Quit
    // reaches this callback. Keep awaiting teardown for actual app termination.
    try {
      await prepareToQuit();
      return AppExitResponse.exit;
    } catch (error) {
      debugPrint('Proxy cleanup failed; keeping the app open: $error');
      return AppExitResponse.cancel;
    }
  }
}
