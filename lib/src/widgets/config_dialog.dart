import 'dart:io';

import '../services/build_capabilities.dart';

import 'package:proxy_ui/l10n/app_language.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/proxy_provider.dart';
import '../models/proxy_config.dart';
import '../models/upstream_endpoint.dart';
import '../screens/proxy_controls.dart';
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
  final _hostFocus = FocusNode();
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig ?? context.read<ProxyState>().config;
    final desktop = context.read<DesktopSettings>();
    _minimizeToTray = desktop.minimizeToTray;
    _launchAtStartup = desktop.launchAtStartup;
    // A saved address that does not parse stays editable as it is.
    final endpoint = UpstreamEndpoint.tryFromHost(
      config.serverHost,
      config.serverPort,
    );
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
    _hostFocus.addListener(() {
      if (!_hostFocus.hasFocus) _absorbEndpoint();
    });
    for (final controller in [
      _hostController,
      _serverPortController,
      _localPortController,
      _sessionKeyController,
      _tunDnsController,
    ]) {
      controller.addListener(_onDraftChanged);
    }
  }

  @override
  void dispose() {
    _hostFocus.dispose();
    _hostController.dispose();
    _serverPortController.dispose();
    _localPortController.dispose();
    _sessionKeyController.dispose();
    _tunDnsController.dispose();
    super.dispose();
  }

  /// Rebuilds the LAN link and the note on what applying will do.
  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  /// Several characters at once is a paste or an autofill; a keystroke is
  /// left alone until the field loses focus, so typing `host:1` mid-way
  /// does not move the 1 into the port.
  void _onHostChanged(String value) {
    if ((value.length - _lastHostLength).abs() > 1 || value.contains('://')) {
      _absorbEndpoint();
    }
    _lastHostLength = _hostController.text.length;
  }

  late int _lastHostLength = _hostController.text.length;

  /// Moves a carrier and a port written into the host field into their own
  /// controls: `quic://host:10811` reads as QUIC, `host` and `10811`.
  void _absorbEndpoint() {
    final split = UpstreamEndpoint.splitInput(_hostController.text);
    if (split == null) return;
    setState(() {
      if (split.transport case final transport?) _transport = transport;
      if (split.port case final port?) _serverPortController.text = '$port';
      _hostController.value = TextEditingValue(
        text: split.host,
        selection: TextSelection.collapsed(offset: split.host.length),
      );
    });
  }

  /// TCP and QUIC listen on different ports, so a server the catalogue
  /// knows takes the port it serves [transport] on.
  void _selectTransport(ProxyState state, UpstreamTransport transport) {
    final host = UpstreamEndpoint.tryFromHost(_hostController.text, 1)?.host;
    final port = host == null ? null : state.catalogPortFor(host, transport);
    setState(() {
      _transport = transport;
      if (port != null) _serverPortController.text = '$port';
    });
  }

  /// The configuration the fields describe, or null while the server
  /// address or a port does not parse.
  ProxyConfigModel? _draft(ProxyState state) {
    final localPort = int.tryParse(_localPortController.text);
    var port = int.tryParse(_serverPortController.text);
    var host = _hostController.text.trim();
    var transport = _transport;
    if (UpstreamEndpoint.splitInput(host) case final split?) {
      host = split.host;
      port = split.port ?? port;
      transport = split.transport ?? transport;
    }
    if (localPort == null || localPort < 1 || localPort > 65535) return null;
    final parsed = UpstreamEndpoint.tryFromHost(host, port ?? 0);
    if (parsed == null) return null;
    final endpoint = UpstreamEndpoint(parsed.host, parsed.port, transport);
    final current = widget.initialConfig ?? state.config;
    return current.copyWith(
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
      tunBypassProcesses: current.tunBypassProcesses,
      tunBypassWeGame: _weGame,
      androidVpnRoutingMode: current.androidVpnRoutingMode,
      androidVpnPackages: current.androidVpnPackages,
      reverseGeo: _reverseGeo,
      secureTransport: _secureTransport,
      setSystemProxy: _setSystemProxy,
    );
  }

  /// One line on what Apply will do to the running proxy, or null when it
  /// only saves.
  String? _applyNotice(ProxyState state) {
    final draft = _draft(state);
    if (draft == null) return null;
    final strings = context.l10n;
    return switch (state.applyImpactOf(draft)) {
      SwitchImpact.none => null,
      SwitchImpact.newSessions => strings.applyKeepsOpenConnections,
      SwitchImpact.restartsTun || SwitchImpact.reconnects =>
        state.isTunRunning
            ? tunRestartNotice(context, strings.applyReconnectsTun(captureName))
            : strings.applyReconnects,
    };
  }

  Future<void> _save() async {
    if (_applying) return;
    _absorbEndpoint();
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
    final draft = _draft(state);
    if (draft == null) {
      ToastUtils.showError(context.l10n.invalidConfiguration);
      return;
    }
    final desktop = context.read<DesktopSettings>();
    final navigator = Navigator.of(context);
    setState(() => _applying = true);
    final applied = await state.applyConfig(draft);

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
    final theme = Theme.of(context);
    final quic = _transport == UpstreamTransport.quic;
    final notice = _applying ? null : _applyNotice(state);

    return PopScope(
      canPop: !_applying,
      child: AlertDialog(
        title: Text(context.l10n.proxyConfiguration),
        content: SizedBox(
          height: size.height / 2,
          width: size.width / 1.5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: IgnorePointer(
                  ignoring: _applying,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ProxyConfigModel.isDesktop &&
                            !BuildCapabilities.usesPacketTunnel)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(context.l10n.systemProxy),
                            value: _setSystemProxy,
                            onChanged: _applying
                                ? null
                                : (value) =>
                                      setState(() => _setSystemProxy = value),
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
                        // Server section. The carrier sits in the heading:
                        // it belongs to the server, TCP unless asked.
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                context.l10n.server,
                                style: theme.textTheme.titleSmall,
                              ),
                            ),
                            Tooltip(
                              message: context.l10n.upstreamTransport,
                              child: SegmentedButton<UpstreamTransport>(
                                key: const Key('server-transport'),
                                showSelectedIcon: false,
                                style: const ButtonStyle(
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                segments: [
                                  for (final transport
                                      in UpstreamTransport.values)
                                    ButtonSegment(
                                      value: transport,
                                      label: Text(transport.label),
                                    ),
                                ],
                                selected: {_transport},
                                onSelectionChanged: (selection) =>
                                    _selectTransport(state, selection.single),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('server-host'),
                          controller: _hostController,
                          focusNode: _hostFocus,
                          onChanged: _onHostChanged,
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
                                key: const Key('server-port'),
                                controller: _serverPortController,
                                decoration: InputDecoration(
                                  labelText: quic
                                      ? context.l10n.serverPortUdp
                                      : context.l10n.serverPort,
                                  hintText: quic ? '10811' : '1081',
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
                        if (quic) ...[
                          const SizedBox(height: 8),
                          _Hint(
                            key: const Key('quic-help'),
                            icon: Icons.verified_user_outlined,
                            text: context.l10n.upstreamTransportHelp,
                          ),
                        ],
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
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
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
                            onChanged: (value) =>
                                setState(() => _allowLan = value),
                          ),
                        if (_allowLan) ...[
                          const SizedBox(height: 8),
                          LanProxyLink(
                            port:
                                int.tryParse(_localPortController.text) ?? 1080,
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
                            onChanged: (v) =>
                                setState(() => _udpDirectFallback = v),
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
                          subtitle: Text(
                            context.l10n.secureTransportDescription,
                          ),
                          value: _secureTransport,
                          onChanged: (v) =>
                              setState(() => _secureTransport = v),
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
                            onChanged: (v) =>
                                setState(() => _minimizeToTray = v),
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
                              onChanged: (v) =>
                                  setState(() => _launchAtStartup = v),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // Next to Apply, so it reads as what the button is about to do.
              if (notice != null) ...[
                const Divider(height: 20),
                _Hint(
                  key: const Key('apply-impact'),
                  icon: Icons.info_outline,
                  text: notice,
                ),
              ],
            ],
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

/// A short line of guidance with its icon, quieter than the form around it.
class _Hint extends StatelessWidget {
  const _Hint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
