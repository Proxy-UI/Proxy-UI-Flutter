import 'package:proxy_ui/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../theme/app_theme.dart';
import '../services/local_controller.dart';
import '../utils/toast_utils.dart';
import '../widgets/link_tile.dart';

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
              if (LocalController.supported) ...[
                const SizedBox(height: 24),
                _LocalControllerCard(state.localController),
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

/// The loopback control API: a switch, then the address and token a script
/// needs, each with its own copy button.
class _LocalControllerCard extends StatefulWidget {
  const _LocalControllerCard(this.controller);

  final LocalController controller;

  @override
  State<_LocalControllerCard> createState() => _LocalControllerCardState();
}

class _LocalControllerCardState extends State<_LocalControllerCard> {
  bool _revealToken = false;

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    ToastUtils.showInfo(message);
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final url = controller.url;
        final token = controller.token;
        final running = controller.running && url != null && token != null;
        if (!running) _revealToken = false;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: running
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.terminal,
                        color: running
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.localController,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            strings.localControllerHint,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (controller.busy)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      Switch(
                        value: controller.running,
                        onChanged: (enabled) =>
                            enabled ? controller.start() : controller.stop(),
                      ),
                  ],
                ),
                if (controller.error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                  // Most often the saved port has been taken meanwhile.
                  if (!controller.running && !controller.busy)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton(
                        onPressed: controller.useNewPort,
                        child: Text(strings.useNewControllerPort),
                      ),
                    ),
                ],
                if (running) ...[
                  const SizedBox(height: 16),
                  LinkTile(
                    icon: Icons.link,
                    title: strings.localControllerAddress,
                    value: url,
                    actions: [
                      IconButton(
                        tooltip: strings.copyUrl,
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () =>
                            _copy(url, strings.urlCopiedToClipboard),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinkTile(
                    icon: Icons.key,
                    title: strings.localControllerToken,
                    value: _revealToken ? token : '•' * 24,
                    actions: [
                      IconButton(
                        tooltip: _revealToken
                            ? strings.hideControllerToken
                            : strings.showControllerToken,
                        icon: Icon(
                          _revealToken
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 20,
                        ),
                        onPressed: () =>
                            setState(() => _revealToken = !_revealToken),
                      ),
                      IconButton(
                        tooltip: strings.copyControllerToken,
                        icon: const Icon(Icons.copy, size: 20),
                        onPressed: () => _copy(token, strings.copied),
                      ),
                      IconButton(
                        tooltip: strings.issueControllerToken,
                        icon: const Icon(Icons.autorenew, size: 20),
                        onPressed: controller.busy
                            ? null
                            : controller.issueNewToken,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          strings.localControllerTokenHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.smart_toy_outlined, size: 18),
                        label: Text(strings.connectAgent),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              _ConnectAgentDialog(url: url, token: token),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Ready-to-paste setup for the common MCP clients, with the token masked on
/// screen and copied in full.
class _ConnectAgentDialog extends StatefulWidget {
  const _ConnectAgentDialog({required this.url, required this.token});

  final String url;
  final String token;

  @override
  State<_ConnectAgentDialog> createState() => _ConnectAgentDialogState();
}

class _ConnectAgentDialogState extends State<_ConnectAgentDialog> {
  AgentSetup _setup = AgentSetup.claudeCode;

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = _setup.snippet(widget.url, '•' * 12);
    return AlertDialog(
      icon: const Icon(Icons.smart_toy_outlined),
      title: Text(strings.connectAgent),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              strings.connectAgentHint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<AgentSetup>(
              segments: [
                for (final setup in AgentSetup.values)
                  ButtonSegment(value: setup, label: Text(setup.label)),
              ],
              selected: {_setup},
              showSelectedIcon: false,
              onSelectionChanged: (selected) =>
                  setState(() => _setup = selected.first),
            ),
            const SizedBox(height: 12),
            Text(
              switch (_setup) {
                AgentSetup.claudeCode => strings.connectAgentClaudeCode,
                AgentSetup.codex => strings.connectAgentCodex,
                AgentSetup.json => strings.connectAgentJson,
                AgentSetup.curl => strings.connectAgentCurl,
              },
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                shown,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: Text(strings.copy),
          onPressed: () {
            Clipboard.setData(
              ClipboardData(text: _setup.snippet(widget.url, widget.token)),
            );
            ToastUtils.showInfo(strings.copied);
          },
        ),
      ],
    );
  }
}
