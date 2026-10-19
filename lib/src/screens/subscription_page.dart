import 'package:proxy_ui/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../theme/app_theme.dart';
import '../utils/toast_utils.dart';

/// Serves Clash and Shadowrocket subscriptions that point other devices on
/// the network at this device's proxy.
class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({super.key});

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage> {
  int _selectedPort = 8080;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = state.subscriptionServiceRunning;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.l10n.subscriptionService,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                context.l10n.subscriptionHint,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: running
                              ? StatusColors.of(context).good
                                    .withValues(alpha: 0.18)
                              : scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(
                          running
                              ? Icons.wifi_tethering
                              : Icons.portable_wifi_off,
                          color: running
                              ? StatusColors.of(context).good
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.l10n.status(
                                running
                                    ? context.l10n.running
                                    : context.l10n.stopped,
                              ),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (running)
                              Text(
                                context.l10n.port2(
                                  state.subscriptionServicePort.toString(),
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      _buildToggleButton(context, state),
                    ],
                  ),
                ),
              ),
              if (running) ...[
                const SizedBox(height: 12),
                _buildSubscriptionCard(
                  context,
                  context.l10n.clashAndroid,
                  state.clashUrl ?? '',
                  Icons.android,
                ),
                const SizedBox(height: 12),
                _buildSubscriptionCard(
                  context,
                  context.l10n.shadowrocketIos,
                  state.shadowrocketUrl ?? '',
                  Icons.phone_iphone,
                ),
                const SizedBox(height: 12),
                Card(
                  color: scheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline,
                          color: scheme.onTertiaryContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.important,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                context
                                    .l10n
                                    .ensureTheLocalProxyIsRunningImportTheSubscription,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: scheme.onTertiaryContainer,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggleButton(BuildContext context, ProxyState state) {
    final running = state.subscriptionServiceRunning;
    final onPressed = state.subscriptionServiceBusy
        ? null
        : () async {
            if (running) {
              await state.stopSubscriptionService();
            } else {
              await _showPortDialog(context, state);
            }
          };
    final icon = state.subscriptionServiceBusy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(running ? Icons.stop : Icons.play_arrow);
    final label = Text(
      state.subscriptionServiceBusy
          ? context.l10n.processing
          : running
          ? context.l10n.stopService
          : context.l10n.startService,
    );
    return running
        ? OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label)
        : FilledButton.icon(onPressed: onPressed, icon: icon, label: label);
  }

  Future<void> _showPortDialog(BuildContext context, ProxyState state) async {
    final strings = context.l10n;
    final controller = TextEditingController(text: _selectedPort.toString());
    try {
      final result = await showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.configurePort),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: context.l10n.port3,
              hintText: '8080',
              helperText: context.l10n.portNumber,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () {
                final port = int.tryParse(controller.text);
                if (port != null && port >= 1024 && port <= 65535) {
                  Navigator.pop(context, port);
                } else {
                  ToastUtils.showError(context.l10n.invalidPortNumber2);
                }
              },
              child: Text(context.l10n.start),
            ),
          ],
        ),
      );

      if (result != null) {
        _selectedPort = result;
        try {
          await state.startSubscriptionService(port: result);
        } catch (e) {
          if (mounted) {
            ToastUtils.showError(strings.failedToStartService(e.toString()));
          }
        }
      }
    } finally {
      controller.dispose();
    }
  }

  Widget _buildSubscriptionCard(
    BuildContext context,
    String title,
    String url,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: url));
                    ToastUtils.showInfo(context.l10n.urlCopiedToClipboard);
                  },
                  icon: const Icon(Icons.copy, size: 18),
                  label: Text(context.l10n.copyUrl),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                url,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
