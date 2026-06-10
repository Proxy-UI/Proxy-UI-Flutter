import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/proxy_config.dart';
import '../providers/proxy_provider.dart';
import '../constants.dart';
import '../utils/toast_utils.dart';
import '../widgets/config_dialog.dart';
import '../widgets/connect_button.dart';

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

  // Connection duration ticker (display only).
  bool _wasRunning = false;
  DateTime? _connectedAt;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    _portController.dispose();
    super.dispose();
  }

  // Track isRunning transitions to start/stop the 1s duration ticker.
  void _syncConnectionTicker(bool running) {
    if (running == _wasRunning) return;
    _wasRunning = running;
    if (running) {
      _connectedAt = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _connectedAt = null;
      _ticker?.cancel();
      _ticker = null;
    }
  }

  String _formatConnectedFor(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ToastUtils.showSuccess('Copied $text');
    }
  }

  void _toggleProxy(ProxyState state) async {
    if (state.isProxyOperationInProgress) return;

    if (state.isRunning) {
      final success = state.stop();
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
        _syncConnectionTicker(state.isRunning);
        final scheme = Theme.of(context).colorScheme;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Stack(
          children: [
            // Aurora ambient behind the hero button while connected
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: state.isRunning ? 1 : 0,
                  duration: longDuration,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        radius: 0.9,
                        colors: [
                          scheme.primary.withValues(
                            alpha: isDark ? 0.14 : 0.10,
                          ),
                          scheme.secondary.withValues(
                            alpha: isDark ? 0.06 : 0.04,
                          ),
                          scheme.secondary.withValues(alpha: 0),
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Port FAB at bottom right
            Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: FloatingActionButton.extended(
                  heroTag: 'port_fab',
                  icon: const Icon(Icons.network_wifi),
                  onPressed: state.isRunning || state.isProxyOperationInProgress
                      ? null
                      : _showPortDialog,
                  label: Text('Port: ${state.config.localPort}'),
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
            // Hero connect button with status
            Center(child: _buildHero(context, state, scheme)),
          ],
        );
      },
    );
  }

  Widget _buildHero(
    BuildContext context,
    ProxyState state,
    ColorScheme scheme,
  ) {
    final busy = state.isProxyOperationInProgress;
    final connected = state.isRunning;
    final statusLabel = busy
        ? (connected ? 'Stopping…' : 'Connecting…')
        : (connected ? 'Connected' : 'Disconnected');
    final statusColor = busy
        ? scheme.tertiary
        : (connected ? scheme.primary : scheme.onSurface);
    final hasServer = state.config.serverHost.isNotEmpty;
    final serverLabel = hasServer
        ? '${state.config.serverHost}:${state.config.serverPort}'
        : 'Configure server first';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ConnectButton(
          isRunning: connected,
          isBusy: busy,
          enabled: state.config.serverHost.isNotEmpty && !busy,
          onPressed: () => _toggleProxy(state),
        ),
        const SizedBox(height: mediumSpacing),
        AnimatedSwitcher(
          duration: shortDuration,
          child: Column(
            key: ValueKey(statusLabel),
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                statusLabel,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                  color: statusColor,
                ),
              ),
              if (connected && !busy && _connectedAt != null) ...[
                const SizedBox(height: tinySpacing),
                Text(
                  _formatConnectedFor(DateTime.now().difference(_connectedAt!)),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: mediumSpacing),
        // Server address pill (tap to copy)
        Tooltip(
          message: hasServer ? 'Tap to copy' : '',
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: hasServer ? () => _copyText(serverLabel) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    serverLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (hasServer) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.copy_rounded,
                      size: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
