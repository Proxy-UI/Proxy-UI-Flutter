import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';

class VpnPage extends StatelessWidget {
  const VpnPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Consumer<ProxyState>(
          builder: (context, state, _) {
            if (!state.vpnSupported) {
              return const Center(
                child: Text('VPN is only supported on Android'),
              );
            }

            final vpnStarting = state.vpnStarting;

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // VPN Status Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Icon(
                            state.vpnRunning
                                ? Icons.vpn_lock
                                : Icons.vpn_lock_outlined,
                            size: 64,
                            color: state.vpnRunning
                                ? Colors.green
                                : Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            vpnStarting
                                ? 'VPN Starting...'
                                : (state.vpnRunning
                                      ? 'VPN Connected'
                                      : 'VPN Disconnected'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: vpnStarting
                                ? null
                                : () => _toggleVpn(context, state),
                            icon: Icon(
                              state.vpnRunning ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(
                              vpnStarting
                                  ? 'Starting...'
                                  : (state.vpnRunning
                                        ? 'Stop VPN'
                                        : 'Start VPN'),
                            ),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Configuration Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Configuration',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          _buildConfigRow(
                            context,
                            'Local Port',
                            state.config.localPort.toString(),
                          ),
                          _buildConfigRow(
                            context,
                            'Server',
                            '${state.config.serverHost}:${state.config.serverPort}',
                          ),
                          _buildConfigRow(
                            context,
                            'Auto Proxy',
                            state.config.autoProxy ? 'Enabled' : 'Disabled',
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Information Card
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.info_outline, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Important',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '• VPN will route all device traffic through the proxy\n'
                            '• Ensure the proxy server is running and accessible\n'
                            '• No need to download Clash or other VPN apps\n'
                            '• VPN permission will be requested on first use',
                            style: TextStyle(height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  ),

                  if (state.lastError != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                state.lastError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildConfigRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleVpn(BuildContext context, ProxyState state) async {
    if (state.vpnRunning) {
      await state.stopVpn();
    } else {
      // Check permission first
      final hasPermission = await state.checkVpnPermission();
      if (!hasPermission && context.mounted) {
        final shouldContinue = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('VPN Permission Required'),
            content: const Text(
              'This app needs VPN permission to route all traffic through the proxy. '
              'You will be asked to grant permission in the next step.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );

        if (shouldContinue != true) return;
      }

      await state.startVpn();
    }
  }
}
