import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';

/// Configuration dialog for proxy settings - simplified AlertDialog style
class ConfigDialog extends StatefulWidget {
  const ConfigDialog({super.key});

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  late TextEditingController _hostController;
  late TextEditingController _serverPortController;
  late TextEditingController _localPortController;
  late TextEditingController _sessionKeyController;
  late bool _autoProxy;
  late bool _reverseGeo;
  late bool _forceCodec;

  @override
  void initState() {
    super.initState();
    final config = context.read<ProxyState>().config;
    _hostController = TextEditingController(text: config.serverHost);
    _serverPortController = TextEditingController(
      text: config.serverPort.toString(),
    );
    _localPortController = TextEditingController(
      text: config.localPort.toString(),
    );
    _sessionKeyController = TextEditingController(
      text: config.sessionKey ?? '',
    );
    _autoProxy = config.autoProxy;
    _reverseGeo = config.reverseGeo;
    _forceCodec = config.forceCodec;
  }

  @override
  void dispose() {
    _hostController.dispose();
    _serverPortController.dispose();
    _localPortController.dispose();
    _sessionKeyController.dispose();
    super.dispose();
  }

  void _save() {
    final state = context.read<ProxyState>();
    final serverPort = int.tryParse(_serverPortController.text);
    final localPort = int.tryParse(_localPortController.text);
    if (serverPort == null || serverPort < 1 || serverPort > 65535) {
      ToastUtils.showError('Invalid server port (1-65535)');
      return;
    }
    if (localPort == null || localPort < 1 || localPort > 65535) {
      ToastUtils.showError('Invalid local port (1-65535)');
      return;
    }

    final currentConfig = state.config;
    state.updateConfig(
      currentConfig.copyWith(
        serverHost: _hostController.text.trim(),
        serverPort: serverPort,
        localPort: localPort,
        sessionKey: _sessionKeyController.text.isEmpty
            ? null
            : _sessionKeyController.text,
        autoProxy: _autoProxy,
        reverseGeo: _reverseGeo,
        forceCodec: _forceCodec,
      ),
    );
    Navigator.of(context).pop();
    ToastUtils.showSuccess('Configuration saved');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return AlertDialog(
      title: const Text('Proxy Configuration'),
      content: SizedBox(
        height: size.height / 2,
        width: size.width / 1.5,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Server section
              Text('Server', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _hostController,
                decoration: const InputDecoration(
                  labelText: 'Server Host',
                  hintText: 'e.g., proxy.example.com',
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _serverPortController,
                      decoration: const InputDecoration(
                        labelText: 'Server Port',
                        hintText: '1081',
                        prefixIcon: Icon(Icons.numbers),
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _sessionKeyController,
                      decoration: const InputDecoration(
                        labelText: 'Session Key',
                        hintText: '32 characters',
                        prefixIcon: Icon(Icons.key_outlined),
                      ),
                      obscureText: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Local section
              Text('Local', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _localPortController,
                decoration: const InputDecoration(
                  labelText: 'Local Port',
                  hintText: '1080',
                  prefixIcon: Icon(Icons.computer_outlined),
                  helperText: 'Port for local proxy server',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 24),
              // Options section
              Text('Options', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Auto Proxy'),
                subtitle: const Text('Route traffic based on geo-location'),
                value: _autoProxy,
                onChanged: (v) => setState(() => _autoProxy = v),
              ),
              SwitchListTile(
                title: const Text('Reverse Geo'),
                subtitle: const Text('Reverse geo-location routing logic'),
                value: _reverseGeo,
                onChanged: (v) => setState(() => _reverseGeo = v),
              ),
              SwitchListTile(
                title: const Text('Force Codec'),
                subtitle: const Text('Force encryption for all connections'),
                value: _forceCodec,
                onChanged: (v) => setState(() => _forceCodec = v),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Dismiss'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
