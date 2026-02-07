import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/proxy_config.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';
import '../widgets/config_dialog.dart';

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
        return Expanded(
          child: Stack(
            children: [
              // Port FAB at bottom right
              Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: FloatingActionButton.extended(
                    heroTag: 'port_fab',
                    icon: const Icon(Icons.network_wifi),
                    onPressed:
                        state.isRunning || state.isProxyOperationInProgress
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
              // Center switch
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
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
                    const SizedBox(height: 32),
                    // Large switch
                    Transform.scale(
                      scale: 1.8,
                      child: Switch(
                        thumbIcon: thumbIcon,
                        value: state.isRunning,
                        onChanged:
                            state.config.serverHost.isEmpty ||
                                state.isProxyOperationInProgress
                            ? null
                            : (_) => _toggleProxy(state),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
