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
import 'src/services/desktop_exit_service.dart';
import 'src/services/desktop_log_service.dart';
import 'src/services/desktop_settings.dart';
import 'src/services/single_instance_service.dart';
import 'src/services/tray_service.dart';
import 'src/services/window_state_service.dart';

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final enableTunOnStartup = arguments.contains('--enable-tun');
  final desktopLogService = DesktopLogService();

  // Initialize window manager for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    // Install the native close guard before the window can first be shown.
    await windowManager.setPreventClose(true);

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
      title: 'Proxy With Flutter',
      titleBarStyle: TitleBarStyle.hidden,
      // macOS retains the native traffic lights inside the unified surface.
      // Windows and Linux render matching controls in Flutter.
      windowButtonVisibility: Platform.isMacOS,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // Before the first show, so the window never appears at the default
      // position and then jumps to the remembered one.
      await WindowStateService.instance.restore();
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(
    ToastificationWrapper(
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
    ),
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
      final exitService = DesktopExitService(
        platform: defaultTargetPlatform,
        hideToTray: () async {
          // Capture the frame before hiding, including programmatic moves that
          // window_manager does not report as interactive move/resize events.
          await WindowStateService.instance.saveNow();
          await TrayService.instance.hideWindow();
        },
        prepareToQuit: _prepareToQuit,
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
      if (proxyState.isRunning || proxyState.isTunRunning) {
        await proxyState.stop();
      }
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
    return Consumer<ThemeState>(
      builder: (context, themeState, _) {
        return MaterialApp(
          title: 'Proxy With Flutter',
          debugShowCheckedModeBanner: false,
          themeMode: themeState.themeMode,
          theme: ThemeData(
            colorSchemeSeed: themeState.colorSeed.color,
            useMaterial3: true,
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: themeState.colorSeed.color,
            useMaterial3: true,
            brightness: Brightness.dark,
          ),
          builder: (context, child) {
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              return VirtualWindowFrame(child: child!);
            }
            return child!;
          },
          home: const HomeScreen(),
        );
      },
    );
  }
}
