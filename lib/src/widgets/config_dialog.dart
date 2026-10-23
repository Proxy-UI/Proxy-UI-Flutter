import 'dart:io';

import '../services/build_capabilities.dart';

import 'package:proxy_ui/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../models/proxy_config.dart';
import '../models/upstream_endpoint.dart';
import '../services/desktop_settings.dart';
import '../utils/toast_utils.dart';
import 'lan_proxy_link.dart';

/// Configuration dialog for proxy settings - simplified AlertDialog style
class ConfigDialog extends StatefulWidget {
  const ConfigDialog({super.key, this.initialConfig});

  final ProxyConfigModel? initialConfig;

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
  late bool _tunFakeIp;
  late TextEditingController _tunDnsController;
  late bool _reverseGeo;
  late bool _secureTransport;
  late UpstreamTransport _transport;
  late bool _minimizeToTray;
  late bool _launchAtStartup;
  late bool _weGame;
  late bool _setSystemProxy;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig ?? context.read<ProxyState>().config;
    final desktop = context.read<DesktopSettings>();
    _minimizeToTray = desktop.minimizeToTray;
    _launchAtStartup = desktop.launchAtStartup;
    UpstreamEndpoint? endpoint;
    try {
      endpoint = UpstreamEndpoint.fromHost(
        config.serverHost,
        config.serverPort,
      );
    } on FormatException {
      // Keep a saved invalid address editable.
    }
    _transport = endpoint?.transport ?? UpstreamTransport.tcp;
    _hostController = TextEditingController(
      text: endpoint?.host ?? config.serverHost,
    );
    _serverPortController = TextEditingController(
      text: (endpoint?.port ?? config.serverPort).toString(),
    );
    _localPortController = TextEditingController(
      text: config.localPort.toString(),
    );
    _localPortController.addListener(_onLocalPortChanged);
    _sessionKeyController = TextEditingController(
      text: config.sessionKey ?? '',
    );
    _allowLan = !BuildCapabilities.usesPacketTunnel && config.allowLan;
    _autoProxy = !BuildCapabilities.isMacAppStore && config.autoProxy;
    _udpEnabled = config.udpEnabled;
    _udpDirectFallback = config.udpDirectFallback;
    _tunFakeIp = config.tunFakeIp;
    _tunDnsController = TextEditingController(text: config.tunDnsServer);
    _reverseGeo = !BuildCapabilities.isMacAppStore && config.reverseGeo;
    _secureTransport = config.secureTransport;
    _weGame = config.tunBypassWeGame;
    _setSystemProxy = config.setSystemProxy;
  }

  @override
  void dispose() {
    _localPortController.removeListener(_onLocalPortChanged);
    _hostController.dispose();
    _serverPortController.dispose();
    _localPortController.dispose();
    _sessionKeyController.dispose();
    _tunDnsController.dispose();
    super.dispose();
  }

  void _onLocalPortChanged() {
    if (_allowLan) setState(() {});
  }

  Future<void> _save() async {
    if (_applying) return;
    final strings = context.l10n;
    final state = context.read<ProxyState>();
    final serverPort = int.tryParse(_serverPortController.text);
    final localPort = int.tryParse(_localPortController.text);
    if (InternetAddress.tryParse(_tunDnsController.text.trim()) == null) {
      ToastUtils.showError(context.l10n.invalidTunDnsServer);
      return;
    }
    if (serverPort == null || serverPort < 1 || serverPort > 65535) {
      ToastUtils.showError(context.l10n.invalidServerPort);
      return;
    }
    if (localPort == null || localPort < 1 || localPort > 65535) {
      ToastUtils.showError(context.l10n.invalidLocalPort);
      return;
    }

    late UpstreamEndpoint endpoint;
    try {
      final parsed = UpstreamEndpoint.fromHost(
        _hostController.text.trim(),
        serverPort,
      );
      endpoint = UpstreamEndpoint(parsed.host, parsed.port, _transport);
    } on FormatException {
      ToastUtils.showError(context.l10n.invalidConfiguration);
      return;
    }
    final currentConfig = widget.initialConfig ?? state.config;
    final desktop = context.read<DesktopSettings>();
    final navigator = Navigator.of(context);
    setState(() => _applying = true);
    final applied = await state.applyConfig(
      currentConfig.copyWith(
        serverHost: endpoint.qualifiedHost,
        serverPort: endpoint.port,
        localPort: localPort,
        allowLan: _allowLan,
        sessionKey: _sessionKeyController.text.isEmpty
            ? null
            : _sessionKeyController.text,
        clearSessionKey: _sessionKeyController.text.isEmpty,
        autoProxy: _autoProxy,
        udpEnabled: _udpEnabled,
        udpDirectFallback: _udpDirectFallback,
        tunFakeIp: _tunFakeIp,
        tunDnsServer: _tunDnsController.text.trim(),
        tunEnabled: state.config.tunEnabled,
        tunBypassProcesses: currentConfig.tunBypassProcesses,
        tunBypassWeGame: _weGame,
        androidVpnRoutingMode: currentConfig.androidVpnRoutingMode,
        androidVpnPackages: currentConfig.androidVpnPackages,
        reverseGeo: _reverseGeo,
        secureTransport: _secureTransport,
        setSystemProxy: _setSystemProxy,
      ),
    );

    if (!mounted) return;
    if (!applied) {
      setState(() => _applying = false);
      ToastUtils.showError(
        state.lastError ?? strings.proxyOperationIsAlreadyInProgress,
      );
      return;
    }

    String? startupError;
    try {
      await desktop.setMinimizeToTray(_minimizeToTray);
      // Windows owns the sign-in entry, so this is the one setting that can be
      // refused; report that rather than closing on a switch that did nothing.
      startupError = DesktopSettings.supportsLaunchAtStartup
          ? await desktop.setLaunchAtStartup(_launchAtStartup)
          : null;
    } catch (error) {
      startupError = error.toString();
    }
    if (!mounted) return;
    setState(() => _applying = false);
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
    final state = context.watch<ProxyState>();

    return PopScope(
      canPop: !_applying,
      child: AlertDialog(
        title: Text(context.l10n.proxyConfiguration),
        content: SizedBox(
          height: size.height / 2,
          width: size.width / 1.5,
          child: IgnorePointer(
            ignoring: _applying,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(context.l10n.configurationDraftDescription),
                  if (state.isRunning)
                    Text(context.l10n.configurationApplyReconnects),
                  const SizedBox(height: 12),
                  if (ProxyConfigModel.isDesktop &&
                      !BuildCapabilities.usesPacketTunnel)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.l10n.systemProxy),
                      value: _setSystemProxy,
                      onChanged: _applying
                          ? null
                          : (value) => setState(() => _setSystemProxy = value),
                    ),
                  if (Platform.isWindows)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(context.l10n.bypassWeGameFamily),
                      subtitle: Text(
                        context.l10n.bypassWeGameFamilyDescription,
                      ),
                      value: _weGame,
                      onChanged: _applying
                          ? null
                          : (value) => setState(() => _weGame = value),
                    ),
                  // Server section
                  Text(
                    context.l10n.server,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<UpstreamTransport>(
                    initialValue: _transport,
                    decoration: InputDecoration(
                      labelText: context.l10n.upstreamTransport,
                      helperText: context.l10n.upstreamTransportHelp,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: UpstreamTransport.tcp,
                        child: Text('TCP'),
                      ),
                      DropdownMenuItem(
                        value: UpstreamTransport.quic,
                        child: Text('QUIC'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _transport = value);
                    },
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
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
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
                  if (!BuildCapabilities.usesPacketTunnel)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: const Icon(Icons.lan_outlined),
                      title: Text(context.l10n.allowLan),
                      subtitle: Text(
                        context
                            .l10n
                            .listenOnAllInterfacesUseOnlyOnTrustedNetworks,
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
                      subtitle: Text(
                        context.l10n.routeTrafficBasedOnGeoLocation,
                      ),
                      value: _autoProxy,
                      onChanged: (v) => setState(() => _autoProxy = v),
                    ),
                  SwitchListTile(
                    title: Text(context.l10n.socksUdp),
                    subtitle: Text(
                      BuildCapabilities.usesPacketTunnel
                          ? context.l10n.packetTunnelUdpProxyDescription
                          : context.l10n.proxyUdpThroughTheServer,
                    ),
                    value: _udpEnabled,
                    onChanged: (v) => setState(() => _udpEnabled = v),
                  ),
                  SwitchListTile(
                    key: const Key('tunFakeIpSwitch'),
                    title: Text(context.l10n.tunFakeIp),
                    subtitle: Text(context.l10n.tunFakeIpDescription),
                    value: _tunFakeIp,
                    onChanged: (v) => setState(() => _tunFakeIp = v),
                  ),
                  TextField(
                    key: const Key('tunDnsServerField'),
                    controller: _tunDnsController,
                    enabled: !_tunFakeIp,
                    decoration: InputDecoration(
                      labelText: context.l10n.tunDnsServer,
                      helperText: context.l10n.tunDnsServerDescription,
                      helperMaxLines: 3,
                    ),
                  ),
                  if (!BuildCapabilities.usesPacketTunnel)
                    SwitchListTile(
                      title: Text(context.l10n.directUdpFallback),
                      subtitle: Text(
                        context.l10n.whenSocksUdpIsOffSendVpnTunUdp,
                      ),
                      value: _udpDirectFallback,
                      onChanged: (v) => setState(() => _udpDirectFallback = v),
                    ),
                  if (!BuildCapabilities.isMacAppStore)
                    SwitchListTile(
                      title: Text(context.l10n.reverseGeo),
                      subtitle: Text(
                        context.l10n.reverseGeoLocationRoutingLogic,
                      ),
                      value: _reverseGeo,
                      onChanged: (v) => setState(() => _reverseGeo = v),
                    ),
                  SwitchListTile(
                    title: Text(context.l10n.secureTransport),
                    subtitle: Text(context.l10n.secureTransportDescription),
                    value: _secureTransport,
                    onChanged: (v) => setState(() => _secureTransport = v),
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
                        context
                            .l10n
                            .hideTheTaskbarButtonWhenMinimizedTheTrayIcon,
                      ),
                      value: _minimizeToTray,
                      onChanged: (v) => setState(() => _minimizeToTray = v),
                    ),
                    if (DesktopSettings.supportsLaunchAtStartup)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(
                          Icons.power_settings_new_outlined,
                        ),
                        title: Text(context.l10n.startAtSignIn),
                        subtitle: Text(
                          context
                              .l10n
                              .launchAutomaticallyWhenYouSignInToWindowsThe,
                        ),
                        value: _launchAtStartup,
                        onChanged: (v) => setState(() => _launchAtStartup = v),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _applying ? null : () => Navigator.of(context).pop(),
            child: Text(context.l10n.dismiss),
          ),
          FilledButton(
            onPressed:
                _applying || state.isProxyOperationInProgress || state.isTunBusy
                ? null
                : _save,
            child: Text(
              _applying
                  ? context.l10n.applyingConfiguration
                  : context.l10n.applyConfiguration,
            ),
          ),
        ],
      ),
    );
  }
}
