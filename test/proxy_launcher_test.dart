import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/proxy_launcher.dart';
import 'package:proxy_ui/src/screens/launcher_page.dart';
import 'package:proxy_ui/src/services/proxy_launcher_service.dart';

class FakeLaunchers extends ProxyLauncherService {
  final entries = <ProxyLauncher>[];
  bool failSave = false;
  final failPaths = <String>{};
  List<LauncherApplication> discovered = [];

  @override
  Future<List<LauncherApplication>> discoverApplications() async => discovered;

  @override
  Future<List<ProxyLauncher>> list() async => List.of(entries);

  @override
  Future<LauncherApplication?> chooseApplication() async =>
      const LauncherApplication(
        'Test App',
        '/Applications/Test App.app',
        LauncherMode.chromium,
      );

  @override
  Future<ProxyLauncher> save(ProxyLauncher launcher) async {
    if (failSave || failPaths.contains(launcher.appPath)) {
      throw PlatformException(code: 'write_failed');
    }
    final saved = ProxyLauncher.fromJson({
      ...launcher.toJson(),
      'id': launcher.id ?? '${entries.length}',
      'launcherPath': '/tmp/managed.app',
    });
    entries.removeWhere((item) => item.id == saved.id);
    entries.add(saved);
    return saved;
  }
}

void main() {
  testWidgets(
    'one click preserves existing apps and retries partial failures',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = FakeLaunchers()
        ..discovered = [
          const LauncherApplication(
            'Claude',
            '/Applications/Claude.app',
            LauncherMode.claudeNative,
            id: 'claude',
          ),
          const LauncherApplication(
            'Codex',
            '/Applications/ChatGPT.app',
            LauncherMode.chromium,
            id: 'codex',
          ),
        ]
        ..failPaths.add('/Applications/Claude.app');
      service.entries.add(
        const ProxyLauncher(
          id: 'existing',
          name: 'My Codex',
          appPath: '/Applications/Codex.app',
          applicationId: 'codex',
          mode: LauncherMode.chromium,
          port: 18080,
          bypassRules: ['.internal.example'],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: LauncherPage(defaultPort: 18765, service: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final generate = find.text('Set up common apps');
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(service.entries.single.port, 18080);
      expect(service.entries.single.bypassRules, ['.internal.example']);
      service.failPaths.clear();
      await tester.tap(generate);
      await tester.pumpAndSettle();
      final claude = service.entries.singleWhere(
        (entry) => entry.applicationId == 'claude',
      );
      expect(claude.mode, LauncherMode.claudeNative);
      expect(claude.port, 18765);
      expect(claude.bypassRules, ProxyLauncher.defaultBypassRules);
      await tester.tap(generate);
      await tester.pumpAndSettle();
      expect(service.entries, hasLength(2));
      expect(service.entries.first.name, 'My Codex');
      await tester.tap(find.text('Edit settings').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(1), '23456');
      await tester.tap(find.text('Use current Proxy port (18765)'));
      await tester.pumpAndSettle();
      expect(find.text('18765'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(1), '23457');
      await tester.enterText(find.byType(TextFormField).last, '*internal*');
      await tester.tap(find.text('Save and apply'));
      await tester.pumpAndSettle();
      expect(service.entries.last.port, 23457);
      expect(service.entries.last.bypassRules, ['*internal*']);
    },
  );

  test('Claude migration preserves its previous port and host rules', () async {
    final service = FakeLaunchers()
      ..discovered = [
        const LauncherApplication(
          'Claude',
          '/Applications/Claude.app',
          LauncherMode.claudeNative,
          id: 'com.anthropic.claudefordesktop',
        ),
      ];
    service.entries.add(
      const ProxyLauncher(
        id: 'legacy',
        name: 'My Claude',
        appPath: '/Applications/Claude.app',
        applicationId: 'com.anthropic.claudefordesktop',
        mode: LauncherMode.chromium,
        port: 19765,
        bypassRules: ['*internal*'],
      ),
    );
    final result = await service.generateKnownApplications(
      port: 18765,
      suffix: 'Proxy',
    );
    expect(result.failures, isEmpty);
    expect(service.entries.single.isNative, isTrue);
    expect(service.entries.single.port, 19765);
    expect(service.entries.single.bypassRules, ['*internal*']);
  });

  test(
    'host rules reject URL and argument injection, preserve wildcard intent',
    () {
      expect(ProxyLauncher.parseRules(' *OA* \n.woa.com\n*oa*\n'), [
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
    },
  );

  testWidgets(
    'create, edit, and reopen retain independent rules without proxy state',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = FakeLaunchers();
      Widget page() => MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LauncherPage(defaultPort: 18765, service: service),
        ),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add application'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save and generate'));
      await tester.pumpAndSettle();
      expect(service.entries.single.port, 18765);
      expect(
        service.entries.single.bypassRules,
        ProxyLauncher.defaultBypassRules,
      );

      await tester.tap(find.text('Add application'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).last,
        '.internal.example\n*oa*',
      );
      await tester.tap(find.text('Save and generate'));
      await tester.pumpAndSettle();
      expect(service.entries.last.bypassRules, ['.internal.example', '*oa*']);
      expect(
        service.entries.first.bypassRules,
        ProxyLauncher.defaultBypassRules,
      );

      await tester.tap(find.text('Edit settings').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, '');
      service.failSave = true;
      await tester.tap(find.text('Save and generate'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        service.entries.first.bypassRules,
        ProxyLauncher.defaultBypassRules,
      );
      service.failSave = false;
      await tester.tap(find.text('Save and generate'));
      await tester.pumpAndSettle();
      expect(
        service.entries.singleWhere((entry) => entry.id == '0').bypassRules,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('.internal.example'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(2));
    },
  );
}
