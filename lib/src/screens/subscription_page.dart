import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  int _selectedPort = 8080;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Consumer<ProxyState>(
          builder: (context, state, _) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Subscription Service',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 32),
                  _buildToggleButton(context, state),
                  const SizedBox(height: 24),
                  _buildStatusCard(state),
                  const SizedBox(height: 24),
                  if (state.subscriptionServiceRunning) ...[
                    _buildSubscriptionCard(
                      context,
                      'Clash (Android)',
                      state.clashUrl ?? '',
                      Icons.android,
                    ),
                    const SizedBox(height: 16),
                    _buildSubscriptionCard(
                      context,
                      'Shadowrocket (iOS)',
                      state.shadowrocketUrl ?? '',
                      Icons.apple,
                    ),
                    const SizedBox(height: 24),
                    _buildInstructions(),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildToggleButton(BuildContext context, ProxyState state) {
    return FilledButton.icon(
      onPressed: () async {
        if (state.subscriptionServiceRunning) {
          await state.stopSubscriptionService();
        } else {
          await _showPortDialog(context, state);
        }
      },
      icon: Icon(
        state.subscriptionServiceRunning ? Icons.stop : Icons.play_arrow,
      ),
      label: Text(
        state.subscriptionServiceRunning ? 'Stop Service' : 'Start Service',
      ),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 20),
        textStyle: const TextStyle(fontSize: 18),
      ),
    );
  }

  Future<void> _showPortDialog(BuildContext context, ProxyState state) async {
    final controller = TextEditingController(text: _selectedPort.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Configure Port'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Port',
            hintText: '8080',
            helperText: 'Port number (1024-65535)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text);
              if (port != null && port >= 1024 && port <= 65535) {
                Navigator.pop(context, port);
              } else {
                ToastUtils.showError('Invalid port number (1024-65535)');
              }
            },
            child: const Text('Start'),
          ),
        ],
      ),
    );

    if (result != null) {
      _selectedPort = result;
      await state.startSubscriptionService(port: result);
    }
  }

  Widget _buildStatusCard(ProxyState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.subscriptionServiceRunning
                      ? Icons.check_circle
                      : Icons.cancel,
                  color: state.subscriptionServiceRunning
                      ? Colors.green
                      : Colors.grey,
                ),
                const SizedBox(width: 8),
                Text(
                  'Status: ${state.subscriptionServiceRunning ? "Running" : "Stopped"}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            if (state.subscriptionServiceRunning) ...[
              const SizedBox(height: 8),
              Text(
                'Port: ${state.subscriptionServicePort}',
                style: TextStyle(color: Colors.grey[600]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSubscriptionCard(
    BuildContext context,
    String title,
    String url,
    IconData icon,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                url,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ToastUtils.showInfo('URL copied to clipboard');
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy URL'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructions() {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      color: isDark ? colorScheme.surfaceContainerHighest : Colors.amber[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: isDark ? colorScheme.primary : Colors.amber[900],
                ),
                const SizedBox(width: 8),
                Text(
                  'Important',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? colorScheme.primary : Colors.amber[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '1. Ensure the local proxy is running\n'
              '2. Import the subscription URL to your client\n'
              '3. Select the LocalProxy node\n'
              '4. For same-device usage: Add subscription BEFORE starting VPN\n'
              '5. For cross-device usage: Ensure devices are on the same network',
              style: TextStyle(
                color: isDark ? colorScheme.onSurface : Colors.amber[900],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
