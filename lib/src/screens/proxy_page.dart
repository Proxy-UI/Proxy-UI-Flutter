import 'package:proxy_ui/l10n/app_language.dart';
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
import '../widgets/tun_diagnostics_dialog.dart';

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
          ToastUtils.showSuccess(context.l10n.proxyStopped);
        } else {
          ToastUtils.showError(
            state.lastError ?? context.l10n.failedToStopProxy,
          );
        }
      }
    } else {
      final success = await state.start();
      if (mounted) {
        if (success) {
          ToastUtils.showSuccess(context.l10n.proxyStarted);
        } else {
          ToastUtils.showError(
            state.lastError ?? context.l10n.failedToStartProxy2,
          );
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
        title: Text(context.l10n.changeLocalProxyServerPort),
        content: TextField(
          controller: _portController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: context.l10n.enterAPortNumber),
        ),
        actions: <Widget>[
          TextButton(
            child: Text(context.l10n.dismiss),
            onPressed: () => Navigator.of(context).pop(),
          ),
          FilledButton(
            child: Text(context.l10n.okay),
            onPressed: () {
              final port = int.tryParse(_portController.text);
              if (port == null || port < 1 || port > 65535) {
                ToastUtils.showError(context.l10n.invalidPortNumber);
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
      ToastUtils.showInfo(
        context.l10n.restartingWithAdministratorPrivilegesForTun,
      );
      state.stopForElevationHandoff();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      // The elevated replacement is the interesting one to debug when TUN setup
      // fails, and its predecessor's log tail explains how it got there.
      await state.flushDesktopLogs();
      exit(0);
    }
    if (result) {
      ToastUtils.showSuccess(
        enabled ? context.l10n.tunModeEnabled : context.l10n.tunModeDisabled,
      );
    } else {
      if (Platform.isMacOS) {
        await _showTunDiagnostics(
          state,
          error: state.lastError ?? context.l10n.failedToChangeTunMode,
          allowRetry: enabled,
        );
      } else {
        await _showTunErrorDialog(
          state.lastError ?? context.l10n.failedToChangeTunMode,
        );
      }
    }
  }

  Future<void> _showTunDiagnostics(
    ProxyState state, {
    String? error,
    bool allowRetry = true,
  }) async {
    final retry = await showDialog<bool>(
      context: context,
      builder: (_) => TunDiagnosticsDialog(
        originalError: error,
        canRetry: allowRetry && state.isRunning && !state.isTunRunning,
      ),
    );
    if (mounted &&
        retry == true &&
        state.isRunning &&
        !state.isTunRunning &&
        !state.isTunBusy) {
      await _toggleTun(state, true);
    }
  }

  Future<void> _showTunErrorDialog(String message) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: Text(context.l10n.tunSetupFailed),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SelectableText(message),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(context.l10n.close),
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
        ToastUtils.showSuccess(context.l10n.configExportedToClipboard);
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(context.l10n.failedToCopy((e).toString()));
      }
    }
  }

  Future<void> _importConfig() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text == null || data!.text!.isEmpty) {
        if (mounted) {
          ToastUtils.showWarning(context.l10n.clipboardIsEmpty);
        }
        return;
      }
      final json = utf8.decode(base64Decode(data.text!));
      final config = ProxyConfigModel.fromJson(jsonDecode(json));
      if (mounted) {
        context.read<ProxyState>().updateConfig(config);
        ToastUtils.showSuccess(context.l10n.configImportedSuccessfully);
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(context.l10n.invalidConfigFormat);
      }
    }
  }

  String _connectionModeLabel(ProxyState state) {
    if (state.isTunRunning) {
      final capture = Platform.isAndroid ? 'VPN' : 'TUN';
      if (state.config.udpEnabled) {
        return context.l10n.tcpUdpProxy((capture).toString());
      }
      return state.config.udpDirectFallback
          ? context.l10n.tcpProxyUdpDirect((capture).toString())
          : context.l10n.tcpProxyUdpBlocked((capture).toString());
    }
    return state.config.udpEnabled
        ? context.l10n.socksTcpUdp
        : context.l10n.socksTcpOnly;
  }

  String _captureStatusLabel(ProxyState state) {
    if (state.isTunBusy) {
      return Platform.isAndroid
          ? context.l10n.configuringVpn
          : context.l10n.configuringTun;
    }
    if (!state.isRunning) return context.l10n.startTheProxyToEnable;
    if (state.isTunRunning) {
      return Platform.isAndroid
          ? context.l10n.routingVia((state.config.localPort).toString())
          : context.l10n.capturingVia((state.config.localPort).toString());
    }
    return Platform.isAndroid
        ? context.l10n.deviceTrafficIsNotCaptured
        : context.l10n.systemTrafficCaptureIsOff;
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
        ? context.l10n.configureAServerToGetStarted
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
                            state.isRunning
                                ? context.l10n.connected
                                : context.l10n.disconnected,
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
                            Platform.isAndroid
                                ? context.l10n.vpnService
                                : context.l10n.tunMode,
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
                        tooltip: context.l10n.vpnApplications(
                          (state.config.androidVpnPackages.length).toString(),
                        ),
                      ),
                    if (Platform.isMacOS)
                      IconButton(
                        onPressed: state.isTunBusy
                            ? null
                            : () => _showTunDiagnostics(state),
                        icon: const Icon(Icons.help_outline),
                        tooltip: context.l10n.tunDiagnosticsGuide,
                      ),
                    if (_supportsTunProcessBypass)
                      IconButton(
                        onPressed: state.isTunBusy
                            ? null
                            : _showTunProcessDialog,
                        icon: const Icon(Icons.security_outlined),
                        tooltip: context.l10n.tunBypassProcesses(
                          (state.config.tunBypassProcesses.length).toString(),
                        ),
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
                      label: Text(context.l10n.config),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: state.isRunning ? null : _showPortDialog,
                      icon: const Icon(Icons.lan_outlined),
                      label: Text(
                        state.config.allowLan
                            ? context.l10n.lan(
                                (state.config.localPort).toString(),
                              )
                            : context.l10n.port(
                                (state.config.localPort).toString(),
                              ),
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
                      label: Text(context.l10n.importLabel),
                    ),
                  ),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: _exportConfig,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(context.l10n.exportLabel),
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
          return LayoutBuilder(
            builder: (context, constraints) =>
                _buildCompactLayout(context, state, constraints),
          );
        }
        return Stack(
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
                            ? context.l10n.lan2(
                                (state.config.localPort).toString(),
                              )
                            : context.l10n.port2(
                                (state.config.localPort).toString(),
                              ),
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
                          tooltip: context.l10n.importFromClipboard,
                          child: const Icon(Icons.file_download),
                        ),
                        const SizedBox(width: 8),
                        FloatingActionButton.small(
                          heroTag: 'export_fab',
                          onPressed: _exportConfig,
                          tooltip: context.l10n.exportToClipboard,
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
                      label: Text(context.l10n.config),
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
                      state.isRunning
                          ? context.l10n.connected
                          : context.l10n.disconnected,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      state.config.serverHost.isEmpty
                          ? context.l10n.configureServerFirst
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
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: state.config.udpEnabled
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
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
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: state.isTunRunning
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant,
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
                                        ? context.l10n.vpnService
                                        : context.l10n.tunMode,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    state.isTunBusy
                                        ? Platform.isAndroid
                                              ? context
                                                    .l10n
                                                    .configuringAndroidVpn
                                              : context
                                                    .l10n
                                                    .configuringAdapterAndRoutes
                                        : !state.isRunning
                                        ? context.l10n.startTheLocalProxyFirst
                                        : state.isTunRunning
                                        ? Platform.isAndroid
                                              ? context.l10n.vpnTraffic(
                                                  (state.config.localPort)
                                                      .toString(),
                                                )
                                              : context.l10n.allTraffic(
                                                  (state.config.localPort)
                                                      .toString(),
                                                )
                                        : Platform.isAndroid
                                        ? context.l10n.androidVpnIsOff
                                        : context
                                              .l10n
                                              .deviceTrafficCaptureIsOff,
                                    style: Theme.of(context).textTheme.bodySmall
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
                            if (Platform.isMacOS)
                              IconButton(
                                onPressed: state.isTunBusy
                                    ? null
                                    : () => _showTunDiagnostics(state),
                                icon: const Icon(Icons.help_outline),
                                tooltip: context.l10n.tunDiagnosticsGuide,
                              ),
                            if (_supportsTunProcessBypass)
                              IconButton(
                                onPressed: state.isTunBusy
                                    ? null
                                    : _showTunProcessDialog,
                                icon: const Icon(Icons.security_outlined),
                                tooltip: context.l10n.tunBypassProcesses(
                                  (state.config.tunBypassProcesses.length)
                                      .toString(),
                                ),
                              ),
                            if (Platform.isAndroid)
                              IconButton(
                                onPressed: state.isTunBusy
                                    ? null
                                    : _showAndroidVpnAppDialog,
                                icon: const Icon(Icons.apps_outlined),
                                tooltip: context.l10n.vpnApplications(
                                  (state.config.androidVpnPackages.length)
                                      .toString(),
                                ),
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
        );
      },
    );
  }
}
