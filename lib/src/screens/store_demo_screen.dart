import 'package:flutter/material.dart';

import '../../l10n/app_language.dart';
import '../services/app_brand.dart';

class StoreDemoButton extends StatelessWidget {
  const StoreDemoButton({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    void open() => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const StoreDemoScreen()));
    if (compact) {
      return IconButton(
        onPressed: open,
        tooltip: context.l10n.storeDemoExplore,
        icon: const Icon(Icons.play_circle_outline),
      );
    }
    return OutlinedButton.icon(
      onPressed: open,
      icon: const Icon(Icons.play_circle_outline),
      label: Text(context.l10n.storeDemoExplore),
    );
  }
}

/// Deliberately has no proxy service, method channel, storage or network dependency.
/// All actions only update this screen's in-memory sample data.
class StoreDemoScreen extends StatefulWidget {
  const StoreDemoScreen({super.key});

  @override
  State<StoreDemoScreen> createState() => _StoreDemoScreenState();
}

class _StoreDemoScreenState extends State<StoreDemoScreen> {
  String _host = 'demo.example.invalid';
  bool _connected = false;
  int _nextNode = 3;
  int _selectedNode = 1;
  final List<int> _nodes = [1, 2];
  final List<String> _events = [];

  void _record(String event) {
    _events.insert(0, event);
    if (_events.length > 50) _events.removeLast();
  }

  Future<void> _configure() async {
    final strings = context.l10n;
    var sampleHost = _host;
    final formKey = GlobalKey<FormState>();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.storeDemoConfigure),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: sampleHost,
            onChanged: (value) => sampleHost = value,
            decoration: InputDecoration(labelText: strings.storeDemoHost),
            validator: (value) =>
                value == null ||
                    value.trim().isEmpty ||
                    RegExp(r'\s').hasMatch(value.trim())
                ? strings.storeDemoInvalidHost
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.storeDemoCancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(context, sampleHost.trim());
              }
            },
            child: Text(strings.storeDemoSave),
          ),
        ],
      ),
    );
    if (!mounted || value == null) return;
    setState(() {
      _host = value;
      _record(strings.storeDemoConfigurationSaved);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${AppBrand.name} · ${strings.storeDemoTitle}'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.all(28),
            children: [
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.storeDemoTitle,
                        style: theme.textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(strings.storeDemoIntro),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _connected
                            ? strings.storeDemoConnected
                            : strings.storeDemoDisconnected,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(strings.storeDemoNoTraffic),
                      const SizedBox(height: 12),
                      SelectableText('$_host:1081'),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: () => setState(() {
                              _connected = !_connected;
                              _record(
                                _connected
                                    ? strings.storeDemoStarted
                                    : strings.storeDemoStopped,
                              );
                            }),
                            icon: Icon(
                              _connected ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(
                              _connected
                                  ? strings.storeDemoDisconnect
                                  : strings.storeDemoConnect,
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _configure,
                            icon: const Icon(Icons.settings_outlined),
                            label: Text(strings.storeDemoConfigure),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(strings.storeDemoNodes, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final node in _nodes)
                Card(
                  child: ListTile(
                    leading: Icon(
                      node == _selectedNode
                          ? Icons.check_circle
                          : Icons.dns_outlined,
                    ),
                    title: Text('${strings.storeDemoNode} $node'),
                    subtitle: Text('node-$node.example.invalid:1081'),
                    trailing: Wrap(
                      children: [
                        TextButton(
                          onPressed: () => setState(() {
                            _selectedNode = node;
                            _host = 'node-$node.example.invalid';
                            _record(strings.storeDemoNodeSelected);
                          }),
                          child: Text(strings.storeDemoSelect),
                        ),
                        IconButton(
                          tooltip: strings.storeDemoRemove,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _nodes.length <= 1
                              ? null
                              : () => setState(() {
                                  _nodes.remove(node);
                                  if (_selectedNode == node) {
                                    _selectedNode = _nodes.first;
                                    _host =
                                        'node-$_selectedNode.example.invalid';
                                  }
                                  _record(strings.storeDemoNodeRemoved);
                                }),
                        ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _nodes.length >= 5
                      ? null
                      : () => setState(() {
                          _nodes.add(_nextNode++);
                          _record(strings.storeDemoNodeAdded);
                        }),
                  icon: const Icon(Icons.add),
                  label: Text(strings.storeDemoAddNode),
                ),
              ),
              const SizedBox(height: 20),
              Text(strings.storeDemoLogs, style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    _events.isEmpty
                        ? strings.storeDemoEmptyLog
                        : _events.join('\n'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(strings.storeDemoFooter),
            ],
          ),
        ),
      ),
    );
  }
}
