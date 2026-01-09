import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/proxy_provider.dart';
import '../providers/theme_provider.dart';
import '../models/proxy_config.dart';

/// Configuration dialog for proxy settings
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
    final colors = ThemeColors.get(context.read<ThemeState>().appTheme);
    state.updateConfig(
      ProxyConfigModel(
        serverHost: _hostController.text.trim(),
        serverPort: int.tryParse(_serverPortController.text) ?? 1081,
        localPort: int.tryParse(_localPortController.text) ?? 1080,
        sessionKey: _sessionKeyController.text.isEmpty
            ? null
            : _sessionKeyController.text,
        autoProxy: _autoProxy,
        reverseGeo: _reverseGeo,
        forceCodec: _forceCodec,
      ),
    );
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Configuration saved'),
        backgroundColor: colors.accent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isSmallScreen = size.width < smallWidthBreakpoint;
    final theme = Theme.of(context);
    final colors = ThemeColors.get(context.watch<ThemeState>().appTheme);

    return Dialog(
      child: Container(
        width: isSmallScreen ? size.width * 0.9 : 500,
        constraints: BoxConstraints(maxHeight: size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme, colors),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(largeSpacing),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionTitle('SERVER', theme, colors),
                    const SizedBox(height: mediumSpacing),
                    _buildServerFields(),
                    const SizedBox(height: largeSpacing),
                    _buildSectionTitle('LOCAL', theme, colors),
                    const SizedBox(height: mediumSpacing),
                    _buildLocalFields(),
                    const SizedBox(height: largeSpacing),
                    _buildSectionTitle('OPTIONS', theme, colors),
                    const SizedBox(height: mediumSpacing),
                    _buildOptions(theme, colors),
                  ],
                ),
              ),
            ),
            _buildActions(theme, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.all(largeSpacing),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colors.primary.withValues(alpha: 0.2),
            colors.accent.withValues(alpha: 0.1),
          ],
        ),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(smallSpacing),
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.settings, color: colors.primary),
          ),
          const SizedBox(width: mediumSpacing),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PROXY CONFIGURATION',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: tinySpacing),
                Text(
                  'Configure your proxy server settings',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, ThemeData theme, ThemeColors colors) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: smallSpacing),
        Text(
          title,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildServerFields() {
    return Column(
      children: [
        TextField(
          controller: _hostController,
          decoration: const InputDecoration(
            labelText: 'Server Host',
            hintText: 'e.g., proxy.example.com',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: mediumSpacing),
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
            const SizedBox(width: mediumSpacing),
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
      ],
    );
  }

  Widget _buildLocalFields() {
    return TextField(
      controller: _localPortController,
      decoration: const InputDecoration(
        labelText: 'Local Port',
        hintText: '1080',
        prefixIcon: Icon(Icons.computer_outlined),
        helperText: 'Port for local proxy server',
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }

  Widget _buildOptions(ThemeData theme, ThemeColors colors) {
    return Column(
      children: [
        _buildSwitchTile(
          title: 'Auto Proxy',
          subtitle: 'Automatically route traffic based on geo-location',
          value: _autoProxy,
          onChanged: (v) => setState(() => _autoProxy = v),
          icon: Icons.auto_awesome,
          theme: theme,
          colors: colors,
        ),
        _buildSwitchTile(
          title: 'Reverse Geo',
          subtitle: 'Reverse geo-location routing logic',
          value: _reverseGeo,
          onChanged: (v) => setState(() => _reverseGeo = v),
          icon: Icons.swap_horiz,
          theme: theme,
          colors: colors,
        ),
        _buildSwitchTile(
          title: 'Force Codec',
          subtitle: 'Force encryption for all connections',
          value: _forceCodec,
          onChanged: (v) => setState(() => _forceCodec = v),
          icon: Icons.lock_outline,
          theme: theme,
          colors: colors,
        ),
      ],
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required IconData icon,
    required ThemeData theme,
    required ThemeColors colors,
  }) {
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.only(bottom: smallSpacing),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: value
              ? colors.primary.withValues(alpha: 0.3)
              : theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: ListTile(
        leading: Icon(
          icon,
          color: value
              ? colors.primary
              : theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        trailing: Switch(value: value, onChanged: onChanged),
      ),
    );
  }

  Widget _buildActions(ThemeData theme, ThemeColors colors) {
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(largeSpacing),
      decoration: BoxDecoration(
        color: (isDark ? const Color(0xFF1A2332) : const Color(0xFFF5F5F5))
            .withValues(alpha: 0.5),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CANCEL'),
          ),
          const SizedBox(width: mediumSpacing),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('SAVE'),
          ),
        ],
      ),
    );
  }
}
