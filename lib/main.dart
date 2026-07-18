import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:window_manager/window_manager.dart';

import 'src/providers/proxy_provider.dart';
import 'src/providers/theme_provider.dart';
import 'src/screens/home_screen.dart';
import 'src/services/desktop_log_service.dart';
import 'src/services/tray_service.dart';

void main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final enableTunOnStartup = arguments.contains('--enable-tun');
  final desktopLogService = DesktopLogService();

  // Initialize window manager for desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

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

class _ProxyAppState extends State<ProxyApp> with WindowListener {
  @override
  void initState() {
    super.initState();

    // Initialize tray and window listener for desktop platforms
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        TrayService.instance.initialize(context);
      });
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    // Hide to tray instead of closing
    await windowManager.hide();
  }

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
