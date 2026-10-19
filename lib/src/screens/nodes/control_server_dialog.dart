import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../providers/proxy_provider.dart';

/// Where the node catalogue comes from: the control server's address and
/// key, and the button that fetches from it.
///
/// Edits are kept as typed (the catalogue page used to persist each
/// keystroke too), so closing the dialog never loses them.
class ControlServerDialog extends StatefulWidget {
  const ControlServerDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const ControlServerDialog(),
  );

  @override
  State<ControlServerDialog> createState() => _ControlServerDialogState();
}

class _ControlServerDialogState extends State<ControlServerDialog> {
  late final ProxyState _state = context.read<ProxyState>();
  late final TextEditingController _host = TextEditingController(
    text: _state.nodesServerHost.isEmpty
        ? _state.config.serverHost
        : _state.nodesServerHost,
  );
  late final TextEditingController _port = TextEditingController(
    text: _state.nodesServerPort.toString(),
  );
  late final TextEditingController _key = TextEditingController(
    text: _state.nodesSessionKey ?? '',
  );
  bool _obscure = true;
  String? _portError;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _key.dispose();
    super.dispose();
  }

  void _persist() {
    _state.updateNodesServerConfig(
      host: _host.text.trim(),
      port: int.tryParse(_port.text),
      sessionKey: _key.text.trim(),
    );
  }

  Future<void> _fetch() async {
    final port = int.tryParse(_port.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _portError = context.l10n.invalidPortNumber);
      return;
    }
    setState(() => _portError = null);
    _persist();
    await _state.fetchNodes();
    if (mounted && _state.nodesError == null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: const Icon(Icons.hub_outlined),
      title: Text(context.l10n.controlServer),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, minWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.l10n.noNodesHint,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: const Key('control-host'),
                    controller: _host,
                    autofocus: _host.text.isEmpty,
                    onChanged: (_) => _persist(),
                    decoration: InputDecoration(
                      labelText: context.l10n.host,
                      hintText: context.l10n.eG,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const Key('control-port'),
                    controller: _port,
                    onChanged: (_) => _persist(),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: context.l10n.port3,
                      errorText: _portError,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _key,
              onChanged: (_) => _persist(),
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: context.l10n.sessionKeyOptional,
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                ),
              ),
            ),
            if (state.nodesError != null) ...[
              const SizedBox(height: 12),
              Text(
                context.l10n.error(state.nodesError!),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.close),
        ),
        FilledButton.icon(
          key: const Key('control-fetch'),
          onPressed: state.isLoadingNodes ? null : _fetch,
          icon: state.isLoadingNodes
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined),
          label: Text(context.l10n.fetchNodes),
        ),
      ],
    );
  }
}
