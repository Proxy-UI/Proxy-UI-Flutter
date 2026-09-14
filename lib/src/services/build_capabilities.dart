import 'dart:io';

/// The Xcode target and Rust feature enforce the same boundary natively.
abstract final class BuildCapabilities {
  static bool get isMacAppStore =>
      Platform.isMacOS && const bool.fromEnvironment('MAC_APP_STORE');
}
