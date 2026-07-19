import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/proxy_config.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';
import '../widgets/config_dialog.dart';
import '../widgets/android_vpn_app_dialog.dart';
import '../widgets/tun_process_dialog.dart';

/// Proxy control page with simple switch and config FAB
class ProxyPage extends StatefulWidget {
  final GlobalKey<ScaffoldState> scaffoldKey;

  const ProxyPage({super.key, required this.scaffoldKey});

  @override
  State<ProxyPage> createState() => _ProxyPageState();
}

class _ProxyPageState extends State<ProxyPage> {
  final TextEditingController _portController = TextEditingController(
    text: '1080',
  );

  final WidgetStateProperty<Icon?> thumbIcon =
      WidgetStateProperty.resolveWith<Icon?>((states) {
        if (states.contains(WidgetState.selected)) {
          return const Icon(Icons.flight_takeoff);
        }
        return const Icon(Icons.flight_land);
      });

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  void _toggleProxy(ProxyState state) async {
    if (state.isRunning) {
      state.stop();
      if (mounted) {
        ToastUtils.showSuccess('Proxy stopped');
      }
    } else {
      final success = await state.start();
      if (mounted) {
        if (success) {
          ToastUtils.showSuccess('Proxy started');
        } else {
          ToastUtils.showError(state.lastError ?? 'Failed to start proxy');
        }
      }
    }
  }

  void _showPortDialog() async {
    final state = context.read<ProxyState>();
    _portController.text = state.config.localPort.toString();

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change local proxy server port'),
        content: TextField(
          controller: _portController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Enter a port number (1-65535)',
          ),
        ),
        actions: <Widget>[
          TextButton(
            child: const Text('Dismiss'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          FilledButton(
            child: const Text('Okay'),
            onPressed: () {
              final port = int.tryParse(_portController.text) ?? 1080;
              state.updateConfig(state.config.copyWith(localPort: port));
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  void _showConfigDialog() {
    showDialog(context: context, builder: (context) => const ConfigDialog());
  }

  void _showTunProcessDialog() {
    showDialog(
      context: context,
      builder: (context) => const TunProcessDialog(),
    );
  }

  void _showAndroidVpnAppDialog() {
    showDialog(
      context: context,
      builder: (context) => const AndroidVpnAppDialog(),
    );
  }

  Future<void> _toggleTun(ProxyState state, bool enabled) async {
    final result = await state.setTunEnabled(enabled);
    if (!mounted) return;
    if (result == null) {
      ToastUtils.showInfo('Restarting with administrator privileges for TUN');
      state.stopForElevationHandoff();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(0);
    }
    if (result) {
      ToastUtils.showSuccess(
        enabled ? 'TUN mode enabled' : 'TUN mode disabled',
      );
    } else {
      await _showTunErrorDialog(state.lastError ?? 'Failed to change TUN mode');
    }
  }

  Future<void> _showTunErrorDialog(String message) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: const Text('TUN setup failed'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SelectableText(message),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _exportConfig() async {
    final state = context.read<ProxyState>();
    final json = jsonEncode(state.config.toJson());
    final encoded = base64Encode(utf8.encode(json));
    try {
      await Clipboard.setData(ClipboardData(text: encoded));
      if (mounted) {
        ToastUtils.showSuccess('Config exported to clipboard');
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError('Failed to copy: $e');
      }
    }
  }

  Future<void> _importConfig() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == null || data!.text!.isEmpty) {
        if (mounted) {
          ToastUtils.showWarning('Clipboard is empty');
        }
        return;
      }
      final json = utf8.decode(base64Decode(data.text!));
      final config = ProxyConfigModel.fromJson(jsonDecode(json));
      if (mounted) {
        context.read<ProxyState>().updateConfig(config);
        ToastUtils.showSuccess('Config imported successfully');
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError('Invalid config format');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        return Expanded(
          child: Stack(
            children: [
              // Port FAB at bottom right
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      FloatingActionButton.extended(
                        heroTag: 'port_fab',
                        icon: const Icon(Icons.network_wifi),
                        onPressed: state.isRunning ? null : _showPortDialog,
                        label: Text('Port: ${state.config.localPort}'),
                      ),
                    ],
                  ),
                ),
              ),
              // Config FAB at bottom left
              Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'import_fab',
                            onPressed: state.isRunning ? null : _importConfig,
                            tooltip: 'Import from clipboard',
                            child: const Icon(Icons.file_download),
                          ),
                          const SizedBox(width: 8),
                          FloatingActionButton.small(
                            heroTag: 'export_fab',
                            onPressed: _exportConfig,
                            tooltip: 'Export to clipboard',
                            child: const Icon(Icons.file_upload),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      FloatingActionButton.extended(
                        heroTag: 'config_fab',
                        icon: const Icon(Icons.settings),
                        onPressed: state.isRunning ? null : _showConfigDialog,
                        label: const Text('Config'),
                      ),
                    ],
                  ),
                ),
              ),
              // Center switch
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 96),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Status text
                      Text(
                        state.isRunning ? 'Connected' : 'Disconnected',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        state.config.serverHost.isEmpty
                            ? 'Configure server first'
                            : '${state.config.serverHost}:${state.config.serverPort}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        state.isTunRunning
                            ? Platform.isAndroid
                                  ? state.config.udpEnabled
                                        ? 'VPN / TCP + UDP'
                                        : 'VPN / TCP only'
                                  : state.config.udpEnabled
                                  ? 'TUN / TCP + UDP'
                                  : 'TUN / TCP only'
                            : state.config.udpEnabled
                            ? 'SOCKS5 TCP + UDP'
                            : 'SOCKS5 TCP only',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: state.config.udpEnabled
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 32),
                      // Large switch
                      Transform.scale(
                        scale: 1.8,
                        child: Switch(
                          thumbIcon: thumbIcon,
                          value: state.isRunning,
                          onChanged:
                              state.config.serverHost.isEmpty || state.isTunBusy
                              ? null
                              : (_) => _toggleProxy(state),
                        ),
                      ),
                      const SizedBox(height: 32),
                      SizedBox(
                        width: 420,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: state.isTunRunning
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                state.isTunRunning
                                    ? Icons.shield
                                    : Icons.shield_outlined,
                                color: state.isTunRunning
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      Platform.isAndroid
                                          ? 'VPN Service'
                                          : 'TUN Mode',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      state.isTunBusy
                                          ? Platform.isAndroid
                                                ? 'Configuring Android VPN...'
                                                : 'Configuring adapter and routes...'
                                          : !state.isRunning
                                          ? 'Start the local proxy first'
                                          : state.isTunRunning
                                          ? Platform.isAndroid
                                                ? 'VPN traffic -> 127.0.0.1:${state.config.localPort}'
                                                : 'All traffic -> 127.0.0.1:${state.config.localPort}'
                                          : Platform.isAndroid
                                          ? 'Android VPN is off'
                                          : 'Device traffic capture is off',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (Platform.isWindows)
                                IconButton(
                                  onPressed: state.isTunBusy
                                      ? null
                                      : _showTunProcessDialog,
                                  icon: const Icon(Icons.security_outlined),
                                  tooltip:
                                      'TUN bypass processes (${state.config.tunBypassProcesses.length})',
                                ),
                              if (Platform.isAndroid)
                                IconButton(
                                  onPressed: state.isTunBusy
                                      ? null
                                      : _showAndroidVpnAppDialog,
                                  icon: const Icon(Icons.apps_outlined),
                                  tooltip:
                                      'VPN applications (${state.config.androidVpnPackages.length})',
                                ),
                              if (state.isTunBusy)
                                const SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              else
                                Switch(
                                  value: state.isTunRunning,
                                  onChanged: state.isRunning
                                      ? (enabled) => _toggleTun(state, enabled)
                                      : null,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
