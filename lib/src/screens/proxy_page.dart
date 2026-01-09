import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/proxy_provider.dart';
import '../providers/theme_provider.dart';
import '../widgets/config_dialog.dart';

/// Proxy control page with large switch and config FAB
class ProxyPage extends StatelessWidget {
  const ProxyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final themeState = context.watch<ThemeState>();
    final colors = ThemeColors.get(themeState.appTheme);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Consumer<ProxyState>(
      builder: (context, state, _) {
        return Stack(
          children: [
            // Animated background color transition
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              color: state.isRunning
                  ? Color.lerp(
                      colors.accent.withValues(alpha: 0.08),
                      theme.scaffoldBackgroundColor,
                      0.7,
                    )
                  : theme.scaffoldBackgroundColor,
            ),
            // Main content
            SafeArea(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Status text
                    _buildStatusText(context, state, colors, theme),
                    const SizedBox(height: extraLargeSpacing),
                    // Large switch
                    _buildSwitch(context, state, colors, isDark, theme),
                    const SizedBox(height: extraLargeSpacing),
                    // Connection info
                    _buildConnectionInfo(context, state, colors, theme),
                  ],
                ),
              ),
            ),
            // Config FAB
            Positioned(
              right: mediumSpacing,
              bottom: mediumSpacing,
              child: FloatingActionButton.extended(
                onPressed: state.isRunning
                    ? null
                    : () => _showConfigDialog(context),
                icon: const Icon(Icons.settings),
                label: const Text('CONFIG'),
                backgroundColor: state.isRunning
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
                    : colors.primary,
              ),
            ),
          ],
        );
      },
    );
  }

  void _showConfigDialog(BuildContext context) {
    showDialog(context: context, builder: (context) => const ConfigDialog());
  }

  void _toggleProxy(BuildContext context, ProxyState state) async {
    if (state.isRunning) {
      state.stop();
    } else {
      final success = await state.start();
      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(state.lastError ?? 'Failed to start proxy'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Widget _buildStatusText(
    BuildContext context,
    ProxyState state,
    ThemeColors colors,
    ThemeData theme,
  ) {
    return Column(
      children: [
        Text(
          state.isRunning ? 'CONNECTED' : 'DISCONNECTED',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 4,
            color: state.isRunning
                ? colors.accent
                : theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: smallSpacing),
        Text(
          state.isRunning ? 'Proxy is active' : 'Tap to connect',
          style: TextStyle(
            fontSize: 14,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildSwitch(
    BuildContext context,
    ProxyState state,
    ThemeColors colors,
    bool isDark,
    ThemeData theme,
  ) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 1.0, end: state.isRunning ? 1.05 : 1.0),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) {
        return Transform.scale(
          scale: scale,
          child: GestureDetector(
            onTap: () => _toggleProxy(context, state),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeOutCubic,
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: state.isRunning
                      ? [colors.accent, colors.accentDark]
                      : isDark
                      ? [const Color(0xFF1E2736), const Color(0xFF151C28)]
                      : [Colors.white, const Color(0xFFF5F5F5)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: state.isRunning
                        ? colors.accent.withValues(alpha: 0.5)
                        : colors.primary.withValues(alpha: 0.2),
                    blurRadius: state.isRunning ? 40 : 20,
                    spreadRadius: state.isRunning ? 8 : 2,
                  ),
                ],
                border: Border.all(
                  color: state.isRunning
                      ? colors.accent.withValues(alpha: 0.8)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                  width: 3,
                ),
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: Icon(
                    state.isRunning ? Icons.flight_takeoff : Icons.flight_land,
                    key: ValueKey(state.isRunning),
                    size: 80,
                    color: state.isRunning
                        ? (isDark ? const Color(0xFF0A0E14) : Colors.white)
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionInfo(
    BuildContext context,
    ProxyState state,
    ThemeColors colors,
    ThemeData theme,
  ) {
    if (state.config.serverHost.isEmpty) {
      return TextButton.icon(
        onPressed: () => _showConfigDialog(context),
        icon: const Icon(Icons.add_circle_outline),
        label: const Text('Configure server'),
        style: TextButton.styleFrom(foregroundColor: colors.primary),
      );
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: state.isRunning ? 1.0 : 0.6,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: largeSpacing,
          vertical: mediumSpacing,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
        ),
        child: Column(
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.dns,
                  size: 16,
                  color: state.isRunning
                      ? colors.accent
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(width: smallSpacing),
                Text(
                  '${state.config.serverHost}:${state.config.serverPort}',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: tinySpacing),
            Text(
              'Local port: ${state.config.localPort}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
