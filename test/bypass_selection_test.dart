import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/desktop_log_service.dart';
import 'package:proxy_ui/src/widgets/tun_process_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:toastification/toastification.dart';

void main() {
  testWidgets(
    'refreshing a launcher tree preserves explicit child exclusions',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      final state = ProxyState(
        service: service,
        desktopLogService: DesktopLogService(enabled: false),
      );
      await tester.runAsync(() async {
        while (!state.isInitialized) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      state.updateConfig(
        ProxyConfigModel(tunBypassProcesses: ['wegame', 'leagueclient']),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            builder: (context, child) => ToastificationWrapper(child: child!),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => ChangeNotifierProvider.value(
                      value: state,
                      child: const TunProcessDialog(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Selecting the parent again must also keep explicit child rules.
      final parent = find.text('wegame${Platform.isWindows ? '.exe' : ''}');
      await tester.tap(parent);
      await tester.pump();
      await tester.tap(parent);
      await tester.pump();
      // Previously loading the parent+child snapshot removed leagueclient.
      service.parentAlive = false;
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pumpAndSettle();
      final child = find.ancestor(
        of: find.text('leagueclient${Platform.isWindows ? '.exe' : ''}'),
        matching: find.byType(InkWell),
      );
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: child, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(state.config.tunBypassProcesses, ['leagueclient', 'wegame']);
      final saved = (await SharedPreferences.getInstance()).getString(
        'proxy_config',
      );
      expect(saved, contains('leagueclient'));
      toastification.dismissAll(delayForAnimation: false);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}

class _Service extends ProxyService {
  bool parentAlive = true;
  @override
  void initLogging() {}
  @override
  bool restoreOrphanedSystemProxy() => false;
  @override
  bool get isRunning => false;
  @override
  bool get isTunRunning => false;
  @override
  String? get tunSelfProcess => 'cipherrelay';
  @override
  List<TunProcessInfo> listTunProcessDetails() => [
    if (parentAlive)
      const TunProcessInfo(
        name: 'wegame',
        pids: [100],
        executablePaths: [],
        instances: [TunProcessInstance(pid: 100)],
      ),
    TunProcessInfo(
      name: 'leagueclient',
      pids: const [101],
      executablePaths: const [],
      instances: [
        TunProcessInstance(pid: 101, parentPid: parentAlive ? 100 : null),
      ],
    ),
  ];
  @override
  void dispose() {}
}
