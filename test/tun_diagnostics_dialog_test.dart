import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/macos_tun_diagnostics.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/l10n/tun_diagnostic_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:proxy_ui/src/widgets/tun_diagnostics_dialog.dart';

const conflict = TunDiagnosticReport(
  routes: [
    TunRouteProbe('1.1.1.1', 'utun4', '192.168.255.10'),
    TunRouteProbe('198.18.0.1', 'utun4', '192.168.255.10'),
  ],
  owners: [
    TunInterfaceOwner(
      interfaceName: 'utun4',
      pid: 84184,
      executablePath: TunInterfaceOwner.smartVpnPath,
    ),
  ],
);
const clear = TunDiagnosticReport(
  routes: [
    TunRouteProbe('1.1.1.1', 'en0', '192.0.2.1'),
    TunRouteProbe('198.18.0.1', 'en0', '192.0.2.1'),
  ],
  owners: [],
);

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<TunDiagnosticReport> Function() load, {
    bool largeText = false,
    Locale? locale = const Locale('zh'),
  }) async {
    SharedPreferences.setMockInitialValues({
      AppLanguage.preferenceKey: locale?.languageCode ?? 'system',
    });
    await AppLanguage.instance.load();
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: AppLanguage.instance,
        builder: (context, _) => MaterialApp(
          locale: AppLanguage.instance.locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(largeText ? 1.6 : 1)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => TunDiagnosticsDialog(
                    originalError: 'Failed to start TUN mode: route conflict',
                    canRetry: true,
                    loadReport: load,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
  }

  testWidgets(
    'shows owner, copies exact commands and refreshes before enabling retry',
    (tester) async {
      var report = conflict;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, () async => report);
      await tester.pumpAndSettle();
      expect(find.textContaining('iOA · SmartVPN · utun4'), findsOneWidget);
      final retry = find.widgetWithText(FilledButton, '重试开启 TUN');
      expect(tester.widget<FilledButton>(retry).onPressed, isNull);
      final command = find.byWidgetPredicate(
        (widget) =>
            widget is CopyableTunCommand &&
            widget.command == conflict.owners.single.temporaryStopCommand,
      );
      final copyButton = find.descendant(
        of: command,
        matching: find.byType(TextButton),
      );
      await tester.ensureVisible(copyButton);
      await tester.tap(copyButton);
      await tester.pumpAndSettle();
      expect(copied, conflict.owners.single.temporaryStopCommand);
      expect(find.text('已复制'), findsOneWidget);
      report = clear;
      await tester.tap(find.text('重新检测'));
      await tester.pumpAndSettle();
      expect(find.textContaining('iOA · SmartVPN'), findsNothing);
      expect(tester.widget<FilledButton>(retry).onPressed, isNotNull);
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byType(TunDiagnosticsDialog), findsNothing);
    },
  );

  testWidgets(
    'a pending or failed refresh removes stale termination instructions',
    (tester) async {
      var result = Future.value(conflict);
      await open(tester, () => result);
      await tester.pumpAndSettle();
      final pending = Completer<TunDiagnosticReport>();
      result = pending.future;
      await tester.tap(find.text('重新检测'));
      await tester.pump();
      expect(
        find.text(conflict.owners.single.temporaryStopCommand!),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '重试开启 TUN'))
            .onPressed,
        isNull,
      );
      pending.completeError(StateError('unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('自动检测暂不可用'), findsOneWidget);
      expect(find.text(TunDiagnosticReport.verifyCommand), findsOneWidget);
    },
  );

  testWidgets(
    'language switch updates steps and summary without changing commands',
    (tester) async {
      var loads = 0;
      await open(tester, () async {
        loads++;
        return conflict;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LanguageMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, 'English'),
      );
      await tester.pumpAndSettle();
      expect(find.text('TUN could not start'), findsOneWidget);
      expect(find.text('Disconnect in the VPN app first'), findsOneWidget);
      expect(find.text('Recheck'), findsOneWidget);
      expect(find.text('Retry TUN'), findsOneWidget);
      expect(find.text('Copy'), findsWidgets);
      expect(
        find.text(conflict.owners.single.temporaryStopCommand!),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Diagnostic summary'));
      await tester.tap(find.text('Diagnostic summary'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          conflict.localizedSummary(lookupAppLocalizations(const Locale('en'))),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byType(LanguageMenuButton));
      await tester.tap(find.byType(LanguageMenuButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, '简体中文'),
      );
      await tester.pumpAndSettle();
      expect(find.text('TUN 暂时无法开启'), findsOneWidget);
      expect(
        find.text(
          conflict.localizedSummary(lookupAppLocalizations(const Locale('zh'))),
        ),
        findsOneWidget,
      );
      expect(loads, 1);
    },
  );

  testWidgets('defaults to system English without a language override', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'en',
      'US',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    await open(tester, () async => clear, locale: null);
    await tester.pumpAndSettle();
    expect(find.text('No conflicting TUN routes found'), findsOneWidget);
    expect(find.text('Recheck'), findsOneWidget);
  });

  testWidgets('an unrelated VPN receives its own name and executable command', (
    tester,
  ) async {
    final owner = TunInterfaceOwner(
      interfaceName: 'utun4',
      pid: 23456,
      executablePath: '/Applications/Example VPN.app/Contents/MacOS/tunnel',
    );
    await open(
      tester,
      () async => TunDiagnosticReport(routes: conflict.routes, owners: [owner]),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Example VPN · tunnel · utun4'), findsOneWidget);
    expect(find.textContaining('iOA'), findsNothing);
    expect(find.textContaining('SmartVPN'), findsNothing);
    expect(find.text(owner.temporaryStopCommand!), findsOneWidget);
    expect(find.text(owner.reopenCommand!), findsOneWidget);
  });

  testWidgets('our own active helper offers no external VPN stop tutorial', (
    tester,
  ) async {
    await open(
      tester,
      () async => TunDiagnosticReport(
        routes: conflict.routes,
        owners: const [
          TunInterfaceOwner(
            interfaceName: 'utun4',
            pid: 91459,
            executablePath:
                '/Applications/proxy_ui.app/Contents/MacOS/http-proxy-tun-helper',
            isCurrentApp: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前流量由 Proxy UI 自己的 TUN 接管'), findsOneWidget);
    expect(find.textContaining('sudo'), findsNothing);
    expect(find.text('先在对应客户端断开连接'), findsNothing);
  });

  testWidgets(
    'steps scroll on a narrow window with large text without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await open(tester, () async => conflict, largeText: true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('测试完成后恢复原连接'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('重新检测'), findsOneWidget);
    },
  );
}
