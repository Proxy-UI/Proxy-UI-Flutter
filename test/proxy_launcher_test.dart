import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/proxy_launcher.dart';
import 'package:proxy_ui/src/screens/launcher_page.dart';
import 'package:proxy_ui/src/services/proxy_launcher_service.dart';
import 'package:toastification/toastification.dart';

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

class FakeLaunchers extends ProxyLauncherService {
  final entries = <ProxyLauncher>[];
  List<LauncherApplication> discovered = [];
  bool failSave = false;
  final iconRequests = <List<String>>[];

  @override
  Future<Map<Object?, Object?>> fetchIcons(List<String> paths) async {
    iconRequests.add(paths);
    // A 1x1 transparent PNG for every installed app.
    return {
      for (final path in paths)
        if (path.startsWith('/Applications/')) path: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    };
  }

  /// Stands in for the native one-click setup: defaults for a new app.
  @override
  Future<ProxyLauncher> setUp(
    LauncherApplication app, {
    required int port,
    required String suffix,
  }) => save(
    ProxyLauncher(
      name: app.mode == LauncherMode.claudeNative
          ? app.name
          : '${app.name} $suffix',
      appPath: app.path,
      applicationId: app.id,
      mode: app.mode,
      port: port,
      bypassRules: ProxyLauncher.defaultBypassRules,
    ),
  );

  @override
  Future<List<LauncherApplication>> discoverApplications() async => discovered;

  @override
  Future<List<ProxyLauncher>> list() async => List.of(entries);

  @override
  Future<ProxyLauncher> save(ProxyLauncher launcher) async {
    if (failSave) throw PlatformException(code: 'write_failed');
    final saved = ProxyLauncher.fromJson({
      ...launcher.toJson(),
      'id': launcher.id ?? launcher.applicationId ?? '${entries.length}',
    });
    // Moving Claude to native settings replaces its generated launcher.
    entries.removeWhere(
      (item) =>
          item.id == saved.id ||
          (saved.isNative && item.applicationId == saved.applicationId),
    );
    entries.add(saved);
    return saved;
  }

  @override
  Future<void> trash(ProxyLauncher launcher) async =>
      entries.removeWhere((item) => item.id == launcher.id);
}

Future<FakeLaunchers> _pumpPage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = FakeLaunchers()
    ..discovered = [_claude, _codex]
    ..entries.add(
      const ProxyLauncher(
        id: 'codex',
        name: 'Codex Proxy Launcher',
        appPath: '/Applications/Codex.app',
        applicationId: 'com.openai.codex',
        mode: LauncherMode.chromium,
        port: 18080,
        bypassRules: ['.internal.example'],
      ),
    );
  await tester.pumpWidget(
    ToastificationWrapper(
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LauncherPage(defaultPort: 18765, service: service),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void main() {
  final strings = lookupAppLocalizations(const Locale('en'));

  test('app proxies exist only on desktop builds', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        ProxyLauncherService.isSupported,
        platform == TargetPlatform.macOS || platform == TargetPlatform.windows,
        reason: '$platform',
      );
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'detected apps exclude configured ones but offer Claude on a launcher',
    () {
      const legacy = ProxyLauncher(
        id: 'legacy',
        name: 'My Claude',
        appPath: '/Applications/Claude.app',
        applicationId: 'com.anthropic.claudefordesktop',
        mode: LauncherMode.chromium,
        port: 19765,
        bypassRules: [],
      );
      const codex = ProxyLauncher(
        id: 'codex',
        name: 'My Codex',
        appPath: '/Applications/Codex.app',
        applicationId: 'com.openai.codex',
        mode: LauncherMode.chromium,
        port: 18080,
        bypassRules: [],
      );
      expect(ProxyLauncherService.pending([_claude, _codex], [legacy, codex]), [
        _claude,
      ]);
    },
  );

  test(
    'icons are fetched once per path and missing ones are omitted',
    () async {
      final service = FakeLaunchers();
      final first = await service.icons([_claude.path, '/missing/App.app']);
      final second = await service.icons([_claude.path, _codex.path]);
      expect(first.keys, [_claude.path]);
      expect(second.keys, [_claude.path, _codex.path]);
      expect(service.iconRequests, [
        [_claude.path, '/missing/App.app'],
        [_codex.path],
      ]);
    },
  );

  test(
    'host rules reject URL and argument injection, preserve wildcard intent',
    () {
      expect(ProxyLauncher.parseRules(' *OA* \n.woa.com, *oa*\n'), [
        '*oa*',
        '.woa.com',
      ]);
      expect(
        ProxyLauncher.validRules(['*oa*', '.woa.com', '10.0.0.1']),
        isTrue,
      );
      expect(ProxyLauncher.validRules(['https://oa.com/path']), isFalse);
      expect(ProxyLauncher.validRules(['oa.com;--proxy-server=evil']), isFalse);
      expect(ProxyLauncher.validRules([r'$(touch /tmp/unwanted)']), isFalse);
      expect(ProxyLauncher.validRules([]), isTrue);
      // NO_PROXY only receives hosts, suffixes and "*.domain".
      expect(ProxyLauncher.appliesToEnvironment('*oa*'), isFalse);
      expect(ProxyLauncher.appliesToEnvironment('*.oa.com'), isTrue);
      expect(ProxyLauncher.appliesToEnvironment('.woa.com'), isTrue);
    },
  );

  testWidgets('add a detected app, sync its port, edit rules, and remove it', (
    tester,
  ) async {
    // The smallest desktop window edits in a dialog.
    final service = await _pumpPage(tester, const Size(800, 900));

    // Only Claude is offered; one click uses the current port and defaults.
    expect(find.text(strings.setUpApp), findsOneWidget);
    await tester.tap(find.text(strings.setUpApp));
    await tester.pumpAndSettle();
    final claude = service.entries.singleWhere((entry) => entry.isNative);
    expect(claude.port, 18765);
    expect(claude.bypassRules, ProxyLauncher.defaultBypassRules);
    expect(find.text(strings.setUpApp), findsNothing);

    // Codex still points at an older port until synced.
    await tester.tap(find.byTooltip(strings.useCurrentProxyPort(18765)));
    await tester.pumpAndSettle();
    ProxyLauncher codex() =>
        service.entries.singleWhere((entry) => entry.id == 'codex');
    expect(codex().port, 18765);
    expect(codex().bypassRules, ['.internal.example']);

    await tester.tap(find.text('Codex Proxy Launcher'));
    await tester.pumpAndSettle();
    final ruleInput = find.widgetWithText(TextField, strings.addDirectRule);
    await tester.enterText(ruleInput, 'https://oa.example/path');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text(strings.invalidLauncherRules), findsOneWidget);
    await tester.enterText(ruleInput, '*oa*, .corp.example');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '.internal.example'),
        matching: find.byIcon(Icons.clear),
      ),
    );
    await tester.pump();

    service.failSave = true;
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(codex().bypassRules, ['.internal.example']);
    service.failSave = false;
    await tester.tap(find.text(strings.save));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(codex().bypassRules, ['*oa*', '.corp.example']);

    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.removeAppProxy));
    await tester.pumpAndSettle();
    await tester.tap(find.text(strings.removeAppProxy).last);
    await tester.pumpAndSettle();
    expect(service.entries.map((entry) => entry.id), [claude.id]);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    // Let the confirmation toasts close.
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('a wide window edits the selected app beside the list', (
    tester,
  ) async {
    final service = await _pumpPage(tester, const Size(1400, 900));
    VoidCallback? save() => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, strings.save))
        .onPressed;
    ProxyLauncher codex() =>
        service.entries.singleWhere((entry) => entry.id == 'codex');

    // The first app is open beside the list; Save waits for a change.
    expect(find.text('/Applications/Codex.app'), findsOneWidget);
    expect(save(), isNull);

    // A one-click setup selects the new app.
    await tester.tap(find.text(strings.setUpApp));
    await tester.pumpAndSettle();
    expect(find.text('/Applications/Claude.app'), findsOneWidget);

    await tester.tap(find.text('Codex Proxy Launcher').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '18080'), '19000');
    await tester.pump();
    expect(save(), isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, strings.save));
    await tester.pumpAndSettle();
    expect(codex().port, 19000);
    // The panel shows the saved settings again, with nothing left to save.
    expect(find.widgetWithText(TextField, '19000'), findsOneWidget);
    expect(save(), isNull);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
}
