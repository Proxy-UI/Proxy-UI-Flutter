import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../services/desktop_settings.dart';
import '../utils/toast_utils.dart';
import 'lan_proxy_link.dart';

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
  late bool _allowLan;
  late bool _autoProxy;
  late bool _udpEnabled;
  late bool _udpDirectFallback;
  late bool _reverseGeo;
  late bool _forceCodec;
  late bool _minimizeToTray;
  late bool _launchAtStartup;

  @override
  void initState() {
    super.initState();
    final config = context.read<ProxyState>().config;
    final desktop = context.read<DesktopSettings>();
    _minimizeToTray = desktop.minimizeToTray;
    _launchAtStartup = desktop.launchAtStartup;
    _hostController = TextEditingController(text: config.serverHost);
    _serverPortController = TextEditingController(
      text: config.serverPort.toString(),
    );
    _localPortController = TextEditingController(
      text: config.localPort.toString(),
    );
    _localPortController.addListener(_onLocalPortChanged);
    _sessionKeyController = TextEditingController(
      text: config.sessionKey ?? '',
    );
    _allowLan = config.allowLan;
    _autoProxy = config.autoProxy;
    _udpEnabled = config.udpEnabled;
    _udpDirectFallback = config.udpDirectFallback;
    _reverseGeo = config.reverseGeo;
    _forceCodec = config.forceCodec;
  }

  @override
  void dispose() {
    _localPortController.removeListener(_onLocalPortChanged);
    _hostController.dispose();
    _serverPortController.dispose();
    _localPortController.dispose();
    _sessionKeyController.dispose();
    super.dispose();
  }

  void _onLocalPortChanged() {
    if (_allowLan) setState(() {});
  }

  Future<void> _save() async {
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
    final desktop = context.read<DesktopSettings>();
    final navigator = Navigator.of(context);
    state.updateConfig(
      currentConfig.copyWith(
        serverHost: _hostController.text.trim(),
        serverPort: serverPort,
        localPort: localPort,
        allowLan: _allowLan,
        sessionKey: _sessionKeyController.text.isEmpty
            ? null
            : _sessionKeyController.text,
        autoProxy: _autoProxy,
        udpEnabled: _udpEnabled,
        udpDirectFallback: _udpDirectFallback,
        tunEnabled: state.config.tunEnabled,
        tunBypassProcesses: state.config.tunBypassProcesses,
        androidVpnRoutingMode: state.config.androidVpnRoutingMode,
        androidVpnPackages: state.config.androidVpnPackages,
        reverseGeo: _reverseGeo,
        needCodecIps: state.config.needCodecIps,
        forceCodec: _forceCodec,
        setSystemProxy: state.config.setSystemProxy,
      ),
    );

    await desktop.setMinimizeToTray(_minimizeToTray);
    // Windows owns the sign-in entry, so this is the one setting that can be
    // refused; report that rather than closing on a switch that did nothing.
    final startupError = DesktopSettings.supportsLaunchAtStartup
        ? await desktop.setLaunchAtStartup(_launchAtStartup)
        : null;

    navigator.pop();
    if (startupError != null) {
      ToastUtils.showError(startupError);
      return;
    }
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
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.lan_outlined),
                title: const Text('Allow LAN'),
                subtitle: const Text(
                  'Listen on all interfaces. Use only on trusted networks.',
                ),
                value: _allowLan,
                onChanged: (value) => setState(() => _allowLan = value),
              ),
              if (_allowLan) ...[
                const SizedBox(height: 8),
                LanProxyLink(
                  port: int.tryParse(_localPortController.text) ?? 1080,
                ),
              ],
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
                title: const Text('SOCKS5 UDP'),
                subtitle: const Text('Proxy UDP through the server'),
                value: _udpEnabled,
                onChanged: (v) => setState(() => _udpEnabled = v),
              ),
              SwitchListTile(
                title: const Text('Direct UDP fallback'),
                subtitle: const Text(
                  'When SOCKS5 UDP is off, send VPN/TUN UDP directly instead of blocking it',
                ),
                value: _udpDirectFallback,
                onChanged: (v) => setState(() => _udpDirectFallback = v),
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
              if (DesktopSettings.isSupported) ...[
                const SizedBox(height: 24),
                Text('Desktop', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.minimize_outlined),
                  title: const Text('Minimize to tray'),
                  subtitle: const Text(
                    'Hide the taskbar button when minimized. The tray icon '
                    'brings the window back.',
                  ),
                  value: _minimizeToTray,
                  onChanged: (v) => setState(() => _minimizeToTray = v),
                ),
                if (DesktopSettings.supportsLaunchAtStartup)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.power_settings_new_outlined),
                    title: const Text('Start at sign-in'),
                    subtitle: const Text(
                      'Launch automatically when you sign in to Windows. The '
                      'proxy still has to be started manually.',
                    ),
                    value: _launchAtStartup,
                    onChanged: (v) => setState(() => _launchAtStartup = v),
                  ),
              ],
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
