import 'src/services/app_brand.dart';
import 'src/services/windows_storage_migration.dart';
import 'src/services/windows_typography.dart';
import 'src/screens/store_privacy_screen.dart';
import 'src/services/build_capabilities.dart';
import 'l10n/app_language.dart';

import 'dart:async' show unawaited;
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

import 'src/providers/proxy_provider.dart';
import 'src/providers/theme_provider.dart';
import 'src/screens/home_screen.dart';
import 'src/theme/app_theme.dart';
import 'src/widgets/theme_transition.dart';
import 'src/widgets/app_render_activity.dart';
import 'src/services/desktop_exit_service.dart';
import 'src/services/desktop_log_service.dart';
import 'src/services/desktop_settings.dart';
import 'src/services/single_instance_service.dart';
import 'src/services/tray_service.dart';
import 'src/services/window_state_service.dart';
import 'src/services/proxy_launcher_service.dart';

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  await WindowsTypography.initialize();
  try {
    await WindowsStorageMigration.initialize();
  } catch (error, stackTrace) {
    debugPrint('Windows configuration migration failed: $error\n$stackTrace');
    // Do not fall through to default settings and start overwriting an
    // installation whose preferences could not be migrated as a unit.
    runApp(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('CipherRelay — 配置迁移失败 / Migration failed'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(
              '原有配置已保留。请修复下方错误后重新启动。\n'
              'Existing settings were preserved. Correct this error and restart.\n\n$error',
            ),
          ),
        ),
      ),
    );
    return;
  }
  await AppLanguage.instance.load();
  if (ProxyLauncherService.isSupported) {
    try {
      // Restore native app routing before an app is opened from its usual icon.
      await ProxyLauncherService.forPlatform().initialize();
    } catch (error) {
      debugPrint('App proxy routing could not start: $error');
      // The app proxy page retries and presents the actionable error.
    }
  }
  final enableTunOnStartup =
      arguments.contains('--enable-tun') && !BuildCapabilities.isMacAppStore;
  final desktopLogService = DesktopLogService();

  // Initialize window manager for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    // Install the native close guard before the window can first be shown.
    await windowManager.setPreventClose(!BuildCapabilities.isMacAppStore);

    try {
      await desktopLogService.initialize();
    } catch (error) {
      debugPrint('Failed to initialize desktop logging: $error');
    }

    final windowOptions = WindowOptions(
      size: Size(1280, 720),
      minimumSize: Size(800, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      title: AppBrand.name,
      titleBarStyle: TitleBarStyle.hidden,
      // macOS retains the native traffic lights inside the unified surface.
      // Windows and Linux render matching controls in Flutter.
      windowButtonVisibility: Platform.isMacOS,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Before the first show, so the window never appears at the default
      // position and then jumps to the remembered one.
      await WindowStateService.instance.restore();
      await WindowStateService.instance.show();
      await windowManager.focus();
    });
  }

  Widget buildApplication() => ToastificationWrapper(
    child: MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => ProxyState(
            enableTunOnStartup: enableTunOnStartup,
            desktopLogService: desktopLogService,
          ),
        ),
        ChangeNotifierProvider(create: (_) => ThemeState()),
        ChangeNotifierProvider(create: (_) => DesktopSettings()..load()),
      ],
      child: const ProxyApp(),
    ),
  );
  runApp(
    BuildCapabilities.isMacAppStore
        ? StorePrivacyGate(applicationBuilder: buildApplication)
        : buildApplication(),
  );
}

class ProxyApp extends StatefulWidget {
  const ProxyApp({super.key});

  @override
  State<ProxyApp> createState() => _ProxyAppState();
}

class _ProxyAppState extends State<ProxyApp>
    with WindowListener, WidgetsBindingObserver {
  DesktopExitService? _exitService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Initialize tray and window listener for desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      unawaited(windowManager.setPreventClose(true));
      final exitService = DesktopExitService(
        platform: defaultTargetPlatform,
        hideToTray: () async {
          // Capture the frame before hiding, including programmatic moves that
          // window_manager does not report as interactive move/resize events.
          await WindowStateService.instance.saveNow();
          await TrayService.instance.hideWindow();
        },
        prepareToQuit: _prepareToQuit,
        shouldRetryQuit: () => TrayService.instance.needsExitRetry,
        retryQuit: () => TrayService.instance.quit(context.read<ProxyState>()),
      );
      _exitService = exitService;
      WidgetsBinding.instance.addObserver(exitService);
      windowManager.addListener(exitService);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        TrayService.instance.initialize(context.read<ProxyState>());
        // Must follow the tray so an activation arriving during startup finds
        // a service that can already show the window.
        SingleInstanceService.instance.initialize();
      });
      windowManager.addListener(this);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final exitService = _exitService;
    if (exitService != null) {
      WidgetsBinding.instance.removeObserver(exitService);
      windowManager.removeListener(exitService);
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
      TrayService.instance.dispose();
      WindowStateService.instance.dispose();
    }
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Only a window following the system changes with it; cross-fade that
    // change rather than letting it snap.
    if (context.read<ThemeState>().themeMode == ThemeMode.system) {
      ThemeTransition.systemChange(context);
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (locales != null && locales.isNotEmpty) {
      AppLanguage.instance.systemLocaleChanged(locales.first);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(TrayService.instance.handleSystemResume());
    }
  }

  /// Cmd-Q and Dock > Quit on macOS must await route/DNS restoration. The tray's
  /// explicit Quit entry awaits its own teardown; Windows session shutdown has
  /// a separate native WM_ENDSESSION cleanup hook.
  Future<void> _prepareToQuit() async {
    if (mounted) {
      final proxyState = context.read<ProxyState>();
      // Awaiting is the point: the exit must not race the privileged helper
      // restoring DNS. `stop` also covers TUN outliving the listener.
      if (!await proxyState.stop()) {
        throw StateError(proxyState.lastError ?? appStrings.failedToStopProxy);
      }
      await TrayService.instance.shutdown();
      await proxyState.flushDesktopLogs();
    }
  }

  @override
  Future<void> onWindowMinimize() async {
    if (!mounted || !context.read<DesktopSettings>().minimizeToTray) return;
    // A background proxy has no reason to keep a taskbar button; the tray icon
    // is the way back in.
    await TrayService.instance.hideWindow();
  }

  @override
  void onWindowResize() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowResized() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowMove() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowMoved() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowMaximize() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowUnmaximize() => WindowStateService.instance.scheduleSave();

  @override
  void onWindowRestore() => WindowStateService.instance.scheduleSave();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguage.instance,
      builder: (context, _) => Consumer<ThemeState>(
        builder: (context, themeState, _) {
          return MaterialApp(
            title: AppBrand.name,
            debugShowCheckedModeBanner: false,
            locale: AppLanguage.instance.locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            themeMode: themeState.themeMode,
            // No lerp: ThemeTransition reveals the new theme over a frozen
            // frame of the old one, and a lerp underneath would flip
            // brightness-chosen colours halfway through it.
            themeAnimationDuration: Duration.zero,
            theme: buildAppTheme(themeState.colorSeed.color, Brightness.light),
            darkTheme: buildAppTheme(
              themeState.colorSeed.color,
              Brightness.dark,
            ),
            builder: (context, child) {
              // The theme switch captures this subtree; see ThemeTransition.
              final content = AppRenderActivity(
                child: ThemeTransitionHost(child: child!),
              );
              if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
                return VirtualWindowFrame(child: content);
              }
              return content;
            },
            home: const HomeScreen(),
          );
        },
      ),
    );
  }
}
