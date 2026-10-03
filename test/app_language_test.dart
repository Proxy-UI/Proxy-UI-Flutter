import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/proxy_config.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/providers/theme_provider.dart';
import 'package:proxy_ui/src/screens/home_screen.dart';
import 'package:proxy_ui/src/services/desktop_settings.dart';
import 'package:proxy_ui/src/widgets/config_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  test(
    'language persists and a manual choice survives system changes',
    () async {
      final language = AppLanguage();
      final reopened = AppLanguage();
      addTearDown(language.dispose);
      addTearDown(reopened.dispose);
      await language.load(systemLocale: const Locale('zh', 'TW'));
      expect(language.locale, const Locale('zh'));
      await language.select('en');
      language.systemLocaleChanged(const Locale('zh'));
      expect(language.locale, const Locale('en'));
      await reopened.load(systemLocale: const Locale('zh'));
      expect(reopened.selection, 'en');
      expect(reopened.strings.proxyConfiguration, 'Proxy Configuration');
      await reopened.select('system');
      expect(reopened.locale, const Locale('zh'));
      reopened.systemLocaleChanged(const Locale('ja'));
      expect(reopened.locale, const Locale('en'));
    },
  );

  test('invalid saved language falls back to system', () async {
    SharedPreferences.setMockInitialValues({AppLanguage.preferenceKey: 'bad'});
    final language = AppLanguage();
    addTearDown(language.dispose);
    await language.load(systemLocale: const Locale('zh'));
    expect(language.selection, 'system');
    expect(language.locale, const Locale('zh'));
  });

  testWidgets(
    'title bar switches every page while preserving the running connection and dialog edits',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await AppLanguage.instance.load(systemLocale: const Locale('en'));
      final service = LanguageTestProxyService();
      final proxy = ProxyState(service: service);
      final theme = ThemeState();
      final desktop = DesktopSettings();
      addTearDown(theme.dispose);
      addTearDown(desktop.dispose);
      await tester.pumpWidget(languageTestApp(proxy, theme, desktop));
      await tester.pumpAndSettle();
      expect(proxy.isInitialized, isTrue);
      proxy.updateConfig(
        ProxyConfigModel(serverHost: 'node.example', setSystemProxy: false),
      );
      await proxy.start();
      await proxy.setTunEnabled(true);
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      final callsBeforeSwitch = List.of(service.calls);

      Future<void> selectLanguage(String label) async {
        await tester.tap(find.byType(LanguageMenuButton));
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(CheckedPopupMenuItem<String>, label),
        );
        await tester.pumpAndSettle();
      }

      await selectLanguage('简体中文');
      for (final label in ['代理', '日志', '订阅', '节点', '已连接', 'TUN 模式', '配置']) {
        expect(find.text(label), findsWidgets);
      }
      await tester.tap(find.text('节点').first);
      await tester.pumpAndSettle();
      expect(find.text('控制服务器'), findsOneWidget);
      await selectLanguage('English');
      expect(find.text('Control Server'), findsOneWidget);
      expect(find.text('Fetch Nodes'), findsOneWidget);
      await tester.tap(find.text('Subscription').first);
      await tester.pumpAndSettle();
      expect(find.text('Subscription Service'), findsOneWidget);
      await selectLanguage('简体中文');
      expect(find.text('订阅服务'), findsOneWidget);
      await tester.tap(find.text('日志').first);
      await tester.pumpAndSettle();
      expect(find.text('暂无日志'), findsOneWidget);
      await selectLanguage('English');
      expect(find.text('No logs yet'), findsOneWidget);
      await tester.tap(find.text('Proxy').first);
      await tester.pumpAndSettle();
      // Configuration is disabled while connected. Open the existing dialog
      // directly to verify that a locale rebuild preserves its edit state too.
      final screenContext = tester.element(find.byType(HomeScreen));
      showDialog<void>(
        context: screenContext,
        builder: (_) => const ConfigDialog(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfigDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'edited.example');
      await AppLanguage.instance.select('zh');
      await tester.pumpAndSettle();
      expect(find.text('代理配置'), findsOneWidget);
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('edited.example'), findsOneWidget);
      expect(proxy.config.serverHost, 'node.example');
      expect(proxy.isRunning, isTrue);
      expect(proxy.isTunRunning, isTrue);
      expect(service.calls, callsBeforeSwitch);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Widget languageTestApp(
  ProxyState proxy,
  ThemeState theme,
  DesktopSettings desktop,
) => MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => proxy),
    ChangeNotifierProvider.value(value: theme),
    ChangeNotifierProvider.value(value: desktop),
  ],
  child: ListenableBuilder(
    listenable: AppLanguage.instance,
    builder: (context, _) => MaterialApp(
      locale: AppLanguage.instance.locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomeScreen(),
    ),
  ),
);

/// This UI test never calls native proxy setup, system settings, or TUN routes.
class LanguageTestProxyService extends ProxyService {
  final calls = <String>[];
  bool _running = false;
  bool _tunRunning = false;
  @override
  void initLogging() {}
  @override
  void setLogLevel(int level) {}
  @override
  bool restoreOrphanedSystemProxy() => false;
  @override
  Future<int> start({
    required String serverHost,
    required int serverPort,
    int localPort = 1080,
    String? sessionKey,
    bool autoProxy = true,
    bool udpEnabled = true,
    bool udpDirectFallback = true,
    bool tunEnabled = false,
    List<String> tunBypassProcesses = const [],
    bool reverseGeo = false,
    String? needCodecIps,
    bool forceCodec = false,
    bool setSystemProxy = false,
    bool allowLan = false,
  }) async {
    calls.add('start');
    _running = true;
    return ProxyResult.ok;
  }

  @override
  Future<int> startTun(List<String> processes) async {
    calls.add('startTun');
    _tunRunning = true;
    return ProxyResult.ok;
  }

  @override
  Future<int> stop() async {
    calls.add('stop');
    _running = _tunRunning = false;
    return ProxyResult.ok;
  }

  @override
  bool get isRunning => _running;
  @override
  bool get isTunRunning => _tunRunning;
  @override
  bool get isElevated => true;
  @override
  String? get lastError => null;
  @override
  void dispose() {}
}
