import '../services/build_capabilities.dart';
import 'package:proxy_ui/l10n/app_language.dart';
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
  late bool _secureTransport;
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
    _allowLan = !BuildCapabilities.isMacAppStore && config.allowLan;
    _autoProxy = !BuildCapabilities.isMacAppStore && config.autoProxy;
    _udpEnabled = config.udpEnabled;
    _udpDirectFallback = config.udpDirectFallback;
    _reverseGeo = !BuildCapabilities.isMacAppStore && config.reverseGeo;
    _forceCodec = config.forceCodec;
    _secureTransport = config.secureTransport;
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
    final strings = context.l10n;
    final state = context.read<ProxyState>();
    final serverPort = int.tryParse(_serverPortController.text);
    final localPort = int.tryParse(_localPortController.text);
    if (serverPort == null || serverPort < 1 || serverPort > 65535) {
      ToastUtils.showError(context.l10n.invalidServerPort);
      return;
    }
    if (localPort == null || localPort < 1 || localPort > 65535) {
      ToastUtils.showError(context.l10n.invalidLocalPort);
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
        secureTransport: _secureTransport,
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
    ToastUtils.showSuccess(strings.configurationSaved);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return AlertDialog(
      title: Text(context.l10n.proxyConfiguration),
      content: SizedBox(
        height: size.height / 2,
        width: size.width / 1.5,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Server section
              Text(
                context.l10n.server,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _hostController,
                decoration: InputDecoration(
                  labelText: context.l10n.serverHost,
                  hintText: context.l10n.eGProxyExampleCom,
                  prefixIcon: Icon(Icons.dns_outlined),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _serverPortController,
                      decoration: InputDecoration(
                        labelText: context.l10n.serverPort,
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
                      decoration: InputDecoration(
                        labelText: context.l10n.sessionKey,
                        hintText: context.l10n.characters,
                        prefixIcon: Icon(Icons.key_outlined),
                      ),
                      obscureText: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // Local section
              Text(
                context.l10n.local,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _localPortController,
                decoration: InputDecoration(
                  labelText: context.l10n.localPort,
                  hintText: '1080',
                  prefixIcon: Icon(Icons.computer_outlined),
                  helperText: context.l10n.portForLocalProxyServer,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              if (!BuildCapabilities.isMacAppStore)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.lan_outlined),
                  title: Text(context.l10n.allowLan),
                  subtitle: Text(
                    context.l10n.listenOnAllInterfacesUseOnlyOnTrustedNetworks,
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
              Text(
                context.l10n.options,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              if (!BuildCapabilities.isMacAppStore)
                SwitchListTile(
                  title: Text(context.l10n.autoProxy),
                  subtitle: Text(context.l10n.routeTrafficBasedOnGeoLocation),
                  value: _autoProxy,
                  onChanged: (v) => setState(() => _autoProxy = v),
                ),
              SwitchListTile(
                title: Text(context.l10n.socksUdp),
                subtitle: Text(context.l10n.proxyUdpThroughTheServer),
                value: _udpEnabled,
                onChanged: (v) => setState(() => _udpEnabled = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.directUdpFallback),
                subtitle: Text(context.l10n.whenSocksUdpIsOffSendVpnTunUdp),
                value: _udpDirectFallback,
                onChanged: (v) => setState(() => _udpDirectFallback = v),
              ),
              if (!BuildCapabilities.isMacAppStore)
                SwitchListTile(
                  title: Text(context.l10n.reverseGeo),
                  subtitle: Text(context.l10n.reverseGeoLocationRoutingLogic),
                  value: _reverseGeo,
                  onChanged: (v) => setState(() => _reverseGeo = v),
                ),
              SwitchListTile(
                title: Text(context.l10n.secureTransport),
                subtitle: Text(context.l10n.secureTransportDescription),
                value: _secureTransport,
                onChanged: (v) => setState(() => _secureTransport = v),
              ),
              SwitchListTile(
                title: Text(context.l10n.forceCodec),
                subtitle: Text(context.l10n.forceEncryptionForAllConnections),
                value: _forceCodec,
                onChanged: _secureTransport
                    ? null
                    : (v) => setState(() => _forceCodec = v),
              ),
              if (DesktopSettings.isSupported) ...[
                const SizedBox(height: 24),
                Text(
                  context.l10n.desktop,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.minimize_outlined),
                  title: Text(context.l10n.minimizeToTray),
                  subtitle: Text(
                    context.l10n.hideTheTaskbarButtonWhenMinimizedTheTrayIcon,
                  ),
                  value: _minimizeToTray,
                  onChanged: (v) => setState(() => _minimizeToTray = v),
                ),
                if (DesktopSettings.supportsLaunchAtStartup)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.power_settings_new_outlined),
                    title: Text(context.l10n.startAtSignIn),
                    subtitle: Text(
                      context.l10n.launchAutomaticallyWhenYouSignInToWindowsThe,
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
          child: Text(context.l10n.dismiss),
          onPressed: () => Navigator.of(context).pop(),
        ),
        FilledButton(onPressed: _save, child: Text(context.l10n.save)),
      ],
    );
  }
}
