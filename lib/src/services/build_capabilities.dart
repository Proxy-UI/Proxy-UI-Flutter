import 'dart:io';

import 'package:flutter/foundation.dart';

/// The Xcode target and Rust feature enforce the same boundary natively.
abstract final class BuildCapabilities {
  static bool get isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMacAppStore =>
      Platform.isMacOS && const bool.fromEnvironment('MAC_APP_STORE');

  /// The system owns forwarding and its lifetime independently of the UI.
  static bool get usesPacketTunnel => isIOS || isMacAppStore;
}
