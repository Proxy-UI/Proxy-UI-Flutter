// Render the App proxies page offline with sample apps, for review.
// Run with: fvm flutter test tool/render_app_proxies_test.dart
// Images land in build/ui-shots/app-proxies/. Real icons are read from
// build/app-proxies-icons/<App name>.png when present (export them with
// NSWorkspace or the Windows shell); otherwise rows show the fallback tile.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/proxy_launcher.dart';
import 'package:proxy_ui/src/screens/launcher_page.dart';
import 'package:proxy_ui/src/services/proxy_launcher_service.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:toastification/toastification.dart';

class _SampleLaunchers extends ProxyLauncherService {
  _SampleLaunchers(this.entries, this.discovered);

  final List<ProxyLauncher> entries;
  final List<LauncherApplication> discovered;

  @override
  Future<List<ProxyLauncher>> list() async => entries;

  @override
  Future<List<LauncherApplication>> discoverApplications() async => discovered;

  @override
  Future<Map<String, Uint8List>> icons(Iterable<String> paths) async => {
    for (final path in paths)
      if (File(_iconFile(path)) case final file when file.existsSync())
        path: file.readAsBytesSync(),
  };

  static String _iconFile(String path) {
    final name = path.split('/').last.replaceFirst('.app', '');
    return 'build/app-proxies-icons/$name.png';
  }
}

const _claude = LauncherApplication(
  'Claude',
  '/Applications/Claude.app',
  LauncherMode.claudeNative,
  id: 'com.anthropic.claudefordesktop',
);
const _codex = LauncherApplication(
  'Codex',
  '/Applications/Codex.app',
  LauncherMode.chromium,
  id: 'com.openai.codex',
);

List<ProxyLauncher> _configured(String suffix) => [
  const ProxyLauncher(
    id: 'claude-native',
    name: 'Claude',
    appPath: '/Applications/Claude.app',
    applicationId: 'com.anthropic.claudefordesktop',
    mode: LauncherMode.claudeNative,
    port: 1080,
    bypassRules: ProxyLauncher.defaultBypassRules,
  ),
  ProxyLauncher(
    id: 'codex',
    name: 'Codex $suffix',
    appPath: '/Applications/Codex.app',
    applicationId: 'com.openai.codex',
    mode: LauncherMode.chromium,
    port: 7890,
    bypassRules: ProxyLauncher.defaultBypassRules,
  ),
  ProxyLauncher(
    id: 'cursor',
    name: 'Cursor $suffix',
    appPath: '/Applications/Cursor.app',
    mode: LauncherMode.environment,
    port: 1080,
    bypassRules: const ['*oa*', '.oa.com', '.woa.com', 'git.corp.example'],
  ),
];

Future<void> _loadFonts() async {
  final sdk = Directory('.fvm/flutter_sdk').resolveSymbolicLinksSync();
  final fonts = '$sdk/bin/cache/artifacts/material_fonts';
  ByteData read(String path) =>
      ByteData.sublistView(File(path).readAsBytesSync());
  final roboto = FontLoader('Roboto');
  for (final name in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ]) {
    roboto.addFont(Future.value(read('$fonts/$name')));
  }
  await roboto.load();
  await (FontLoader('NotoSansSC')
        ..addFont(Future.value(read('assets/fonts/NotoSansSC-Variable.ttf'))))
      .load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(Future.value(read('$fonts/MaterialIcons-Regular.otf')))).load();
}

ThemeData _theme(Brightness brightness) {
  final theme = buildAppTheme(const Color(0xff6750a4), brightness);
  TextTheme withFonts(TextTheme text) => text.apply(
    fontFamily: 'Roboto',
    fontFamilyFallback: const ['NotoSansSC'],
  );
  return theme.copyWith(
    textTheme: withFonts(theme.textTheme),
    primaryTextTheme: withFonts(theme.primaryTextTheme),
  );
}

void main() {
  testWidgets('render the App proxies page with sample apps', (tester) async {
    await tester.runAsync(_loadFonts);
    final boundary = GlobalKey();
    tester.view.devicePixelRatio = 1;

    Future<void> show(
      Size size,
      Brightness brightness,
      String language,
      ProxyLauncherService service,
    ) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: ToastificationWrapper(
            child: MaterialApp(
              key: UniqueKey(),
              debugShowCheckedModeBanner: false,
              locale: Locale(language),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: _theme(brightness),
              home: Scaffold(
                body: LauncherPage(defaultPort: 1080, service: service),
              ),
            ),
          ),
        ),
      );
      // Icons decode outside the fake clock.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
    }

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/ui-shots/app-proxies/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> open(String text) async {
      await tester.tap(find.text(text).first);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
    }

    const desktop = Size(1100, 760);
    const minimum = Size(704, 600);
    final zh = lookupAppLocalizations(const Locale('zh'));
    final en = lookupAppLocalizations(const Locale('en'));
    final configuredZh = _configured(zh.proxyLauncherSuffix);
    final configuredEn = _configured(en.proxyLauncherSuffix);

    await show(
      desktop,
      Brightness.light,
      'zh',
      _SampleLaunchers([], [_claude, _codex]),
    );
    await capture('01-first-run-light-zh');
    await show(desktop, Brightness.dark, 'en', _SampleLaunchers([], []));
    await capture('02-empty-dark-en');

    await show(
      desktop,
      Brightness.light,
      'zh',
      _SampleLaunchers(configuredZh, [_claude, _codex]),
    );
    await capture('03-configured-light-zh');
    await open(configuredZh[1].name);
    await capture('04-edit-launcher-light-zh');

    await show(
      desktop,
      Brightness.dark,
      'en',
      _SampleLaunchers(configuredEn, [_claude, _codex]),
    );
    await capture('05-configured-dark-en');
    await open(configuredEn[2].name);
    await capture('06-edit-environment-dark-en');
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    await open('Claude');
    await capture('07-edit-claude-dark-en');
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await capture('08-row-menu-dark-en');
    await tester.tap(find.text(en.removeAppProxy));
    await tester.pumpAndSettle();
    await capture('09-remove-dark-en');

    // The smallest desktop window (800x600) leaves this beside the rail.
    await show(
      minimum,
      Brightness.light,
      'en',
      _SampleLaunchers(configuredEn.sublist(1), [_claude, _codex]),
    );
    await capture('10-min-window-light-en');
    await show(
      minimum,
      Brightness.dark,
      'zh',
      _SampleLaunchers(configuredZh, [_claude, _codex]),
    );
    await capture('11-min-window-dark-zh');
    await open(configuredZh[1].name);
    await capture('12-edit-min-window-dark-zh');

    await tester.pumpWidget(const SizedBox());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
