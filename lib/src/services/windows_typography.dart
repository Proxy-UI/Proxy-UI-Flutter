import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A bundled CJK face avoids depending on Windows' per-machine font fallback.
class WindowsTypography {
  static const family = 'Noto Sans SC';
  static const fontAsset = 'assets/fonts/NotoSansSC-Variable.ttf';
  static const licenseAsset = 'assets/fonts/OFL-NotoSansSC.txt';

  static String? get themeFamily =>
      defaultTargetPlatform == TargetPlatform.windows ? family : null;

  static List<String>? get themeFallback =>
      defaultTargetPlatform == TargetPlatform.windows ? const [family] : null;

  static Future<void> initialize() async {
    if (!Platform.isWindows) return;
    // Load before the first frame, including when the machine is offline.
    final loader = FontLoader(family)..addFont(rootBundle.load(fontAsset));
    await loader.load();
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await rootBundle.loadString(licenseAsset));
    });
  }
}
