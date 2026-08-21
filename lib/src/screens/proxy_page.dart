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
import '../widgets/lan_proxy_link.dart';
import '../widgets/tun_process_dialog.dart';

/// Whether this platform can pick processes to keep out of the tunnel.
///
/// Windows and macOS both resolve a captured session back to its owning process
/// and can relay it directly through the physical interface. Android and iOS
/// leave per-application routing to the platform VPN API, which has its own
/// picker, and Linux has no process enumeration wired up.
final bool _supportsTunProcessBypass = Platform.isWindows || Platform.isMacOS;

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
    if (state.isProxyOperationInProgress) return;

    if (state.isRunning) {
      final success = await state.stop();
      if (mounted) {
        if (success) {
          ToastUtils.showSuccess('Proxy stopped');
        } else {
          ToastUtils.showError(state.lastError ?? 'Failed to stop proxy');
        }
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
              final port = int.tryParse(_portController.text);
              if (port == null || port < 1 || port > 65535) {
                ToastUtils.showError('Invalid port number (1-65535)');
                return;
              }
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
      useSafeArea: false,
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
      // The elevated replacement is the interesting one to debug when TUN setup
      // fails, and its predecessor's log tail explains how it got there.
      await state.flushDesktopLogs();
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

  String _connectionModeLabel(ProxyState state) {
    if (state.isTunRunning) {
      final capture = Platform.isAndroid ? 'VPN' : 'TUN';
      if (state.config.udpEnabled) return '$capture / TCP + UDP proxy';
      return state.config.udpDirectFallback
          ? '$capture / TCP proxy + UDP direct'
          : '$capture / TCP proxy + UDP blocked';
    }
    return state.config.udpEnabled ? 'SOCKS5 TCP + UDP' : 'SOCKS5 TCP only';
  }

  String _captureStatusLabel(ProxyState state) {
    if (state.isTunBusy) {
      return Platform.isAndroid ? 'Configuring VPN...' : 'Configuring TUN...';
    }
    if (!state.isRunning) return 'Start the proxy to enable';
    if (state.isTunRunning) {
      return Platform.isAndroid
          ? 'Routing via 127.0.0.1:${state.config.localPort}'
          : 'Capturing via 127.0.0.1:${state.config.localPort}';
    }
    return Platform.isAndroid
        ? 'Device traffic is not captured'
        : 'System traffic capture is off';
  }

  Widget _buildCompactLayout(
    BuildContext context,
    ProxyState state,
    BoxConstraints constraints,
  ) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final canToggleProxy =
        state.config.serverHost.isNotEmpty && !state.isTunBusy;
    final endpoint = state.config.serverHost.isEmpty
        ? 'Configure a server to get started'
        : '${state.config.serverHost}:${state.config.serverPort}';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: (constraints.maxHeight - 32).clamp(0, double.infinity),
        ),
        child: IntrinsicHeight(
          child: Column(
            children: [
              AnimatedContainer(
                key: const Key('compact-connection-panel'),
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: state.isRunning
                      ? colors.primaryContainer.withValues(alpha: .32)
                      : colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: state.isRunning
                            ? colors.primaryContainer
                            : colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        state.isRunning
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        color: state.isRunning
                            ? colors.onPrimaryContainer
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            state.isRunning ? 'Connected' : 'Disconnected',
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            endpoint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _connectionModeLabel(state),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: state.config.udpEnabled
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      thumbIcon: thumbIcon,
                      value: state.isRunning,
                      onChanged: canToggleProxy
                          ? (_) => _toggleProxy(state)
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('compact-vpn-panel'),
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: state.isTunRunning
                        ? colors.primary.withValues(alpha: .65)
                        : colors.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      state.isTunRunning ? Icons.shield : Icons.shield_outlined,
                      color: state.isTunRunning
                          ? colors.primary
                          : colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Platform.isAndroid ? 'VPN Service' : 'TUN Mode',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _captureStatusLabel(state),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
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
                    if (_supportsTunProcessBypass)
                      IconButton(
                        onPressed: state.isTunBusy
                            ? null
                            : _showTunProcessDialog,
                        icon: const Icon(Icons.security_outlined),
                        tooltip:
                            'TUN bypass processes (${state.config.tunBypassProcesses.length})',
                      ),
                    if (state.isTunBusy)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
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
              if (state.config.allowLan) ...[
                const SizedBox(height: 12),
                LanProxyLink(port: state.config.localPort),
              ],
              const SizedBox(height: 20),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: state.isRunning ? null : _showConfigDialog,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('Config'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.isRunning ? null : _showPortDialog,
                      icon: const Icon(Icons.lan_outlined),
                      label: Text(
                        state.config.allowLan
                            ? 'LAN ${state.config.localPort}'
                            : 'Port ${state.config.localPort}',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: state.isRunning ? null : _importConfig,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('Import'),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _exportConfig,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('Export'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        if (MediaQuery.sizeOf(context).width < 600) {
          return Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) =>
                  _buildCompactLayout(context, state, constraints),
            ),
          );
        }
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
                        onPressed:
                            state.isRunning || state.isProxyOperationInProgress
                            ? null
                            : _showPortDialog,
                        label: Text(
                          state.config.allowLan
                              ? 'LAN: ${state.config.localPort}'
                              : 'Port: ${state.config.localPort}',
                        ),
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
                            onPressed:
                                state.isRunning ||
                                    state.isProxyOperationInProgress
                                ? null
                                : _importConfig,
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
                        onPressed:
                            state.isRunning || state.isProxyOperationInProgress
                            ? null
                            : _showConfigDialog,
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
                        _connectionModeLabel(state),
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
                              state.config.serverHost.isEmpty ||
                                  state.isTunBusy ||
                                  state.isProxyOperationInProgress
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
                              if (_supportsTunProcessBypass)
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
                      if (state.config.allowLan) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: 420,
                          child: LanProxyLink(port: state.config.localPort),
                        ),
                      ],
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
