import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ffi/proxy_service.dart';
import '../providers/proxy_provider.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _hostController;
  late TextEditingController _serverPortController;
  late TextEditingController _localPortController;
  late TextEditingController _sessionKeyController;

  @override
  void initState() {
    super.initState();
    final config = context.read<ProxyState>().config;
    _hostController = TextEditingController(text: config.serverHost);
    _serverPortController =
        TextEditingController(text: config.serverPort.toString());
    _localPortController =
        TextEditingController(text: config.localPort.toString());
    _sessionKeyController = TextEditingController(text: config.sessionKey ?? '');
  }

  @override
  void dispose() {
    _hostController.dispose();
    _serverPortController.dispose();
    _localPortController.dispose();
    _sessionKeyController.dispose();
    super.dispose();
  }

  void _saveConfig() {
    if (!_formKey.currentState!.validate()) return;

    final provider = context.read<ProxyState>();
    provider.updateConfig(provider.config.copyWith(
      serverHost: _hostController.text.trim(),
      serverPort: int.tryParse(_serverPortController.text) ?? 1081,
      localPort: int.tryParse(_localPortController.text) ?? 1080,
      sessionKey: _sessionKeyController.text.isEmpty
          ? null
          : _sessionKeyController.text,
    ));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configuration saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Proxy UI'),
        actions: [
          Consumer<ProxyState>(
            builder: (context, provider, _) => DropdownButton<int>(
              value: provider.minLogLevel,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 0, child: Text('TRACE')),
                DropdownMenuItem(value: 1, child: Text('DEBUG')),
                DropdownMenuItem(value: 2, child: Text('INFO')),
                DropdownMenuItem(value: 3, child: Text('WARN')),
                DropdownMenuItem(value: 4, child: Text('ERROR')),
              ],
              onChanged: (v) => provider.setMinLogLevel(v ?? 0),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => context.read<ProxyState>().clearLogs(),
            tooltip: 'Clear logs',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildControlPanel(),
          const Divider(height: 1),
          Expanded(child: _buildLogView()),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Consumer<ProxyState>(
      builder: (context, provider, _) {
        return Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Status indicator
                  Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: provider.isRunning ? Colors.green : Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        provider.isRunning ? 'Running' : 'Stopped',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      // Start/Stop button
                      FilledButton.icon(
                        onPressed: provider.isRunning
                            ? () => provider.stop()
                            : () => provider.start(),
                        icon: Icon(
                            provider.isRunning ? Icons.stop : Icons.play_arrow),
                        label: Text(provider.isRunning ? 'Stop' : 'Start'),
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              provider.isRunning ? Colors.red : Colors.green,
                        ),
                      ),
                    ],
                  ),
                  if (provider.lastError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      provider.lastError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // Server configuration
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _hostController,
                          decoration: const InputDecoration(
                            labelText: 'Server Host',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: !provider.isRunning,
                          validator: (v) =>
                              v?.isEmpty == true ? 'Required' : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          controller: _serverPortController,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: !provider.isRunning,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _localPortController,
                          decoration: const InputDecoration(
                            labelText: 'Local Port',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: !provider.isRunning,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _sessionKeyController,
                          decoration: const InputDecoration(
                            labelText: 'Session Key (32 chars)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          enabled: !provider.isRunning,
                          obscureText: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Options
                  Wrap(
                    spacing: 16,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: provider.config.autoProxy,
                            onChanged: provider.isRunning
                                ? null
                                : (v) => provider.updateConfig(
                                    provider.config.copyWith(autoProxy: v)),
                          ),
                          const Text('Auto Proxy'),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: provider.config.reverseGeo,
                            onChanged: provider.isRunning
                                ? null
                                : (v) => provider.updateConfig(
                                    provider.config.copyWith(reverseGeo: v)),
                          ),
                          const Text('Reverse Geo'),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: provider.config.forceCodec,
                            onChanged: provider.isRunning
                                ? null
                                : (v) => provider.updateConfig(
                                    provider.config.copyWith(forceCodec: v)),
                          ),
                          const Text('Force Codec'),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton(
                      onPressed: provider.isRunning ? null : _saveConfig,
                      child: const Text('Save Config'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLogView() {
    return Consumer<ProxyState>(
      builder: (context, provider, _) {
        final logs = provider.filteredLogs;
        if (logs.isEmpty) {
          return const Center(
            child: Text('No logs yet', style: TextStyle(color: Colors.grey)),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          itemCount: logs.length,
          reverse: true,
          itemBuilder: (context, index) {
            final log = logs[logs.length - 1 - index];
            return _LogItem(entry: log);
          },
        );
      },
    );
  }
}

class _LogItem extends StatelessWidget {
  final LogEntry entry;

  const _LogItem({required this.entry});

  Color _levelColor(int level) {
    switch (level) {
      case 0:
        return Colors.grey;
      case 1:
        return Colors.blue;
      case 2:
        return Colors.green;
      case 3:
        return Colors.orange;
      case 4:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final time =
        '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            time,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: _levelColor(entry.level).withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.levelName,
              style: TextStyle(
                fontSize: 10,
                color: _levelColor(entry.level),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              entry.message,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
