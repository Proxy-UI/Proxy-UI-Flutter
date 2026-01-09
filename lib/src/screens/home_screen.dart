import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/theme_provider.dart';
import 'proxy_page.dart';
import 'log_page.dart';

/// Main navigation container with responsive layout
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  void _onDestinationSelected(int index) {
    setState(() => _selectedIndex = index);
  }

  Widget _buildPage() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _selectedIndex == 0
          ? const ProxyPage(key: ValueKey('proxy'))
          : const LogPage(key: ValueKey('log')),
    );
  }

  void _showThemeSheet() {
    final themeState = context.read<ThemeState>();
    showModalBottomSheet(
      context: context,
      builder: (context) => _ThemeSheet(themeState: themeState),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final themeState = context.watch<ThemeState>();
    final colorScheme = Theme.of(context).colorScheme;

    // Constrain max width to avoid TransformLayer issues
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1600),
        child: width < smallWidthBreakpoint
            ? _buildSmallLayout(colorScheme, themeState)
            : _buildLargeLayout(width, colorScheme, themeState),
      ),
    );
  }

  Widget _buildSmallLayout(ColorScheme colorScheme, ThemeState themeState) {
    return Scaffold(
      body: _buildPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.flight_outlined),
            selectedIcon: Icon(Icons.flight),
            label: 'Proxy',
          ),
          NavigationDestination(
            icon: Icon(Icons.terminal_outlined),
            selectedIcon: Icon(Icons.terminal),
            label: 'Logs',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _showThemeSheet,
        child: Icon(themeState.isDark ? Icons.dark_mode : Icons.light_mode),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }

  Widget _buildLargeLayout(
    double width,
    ColorScheme colorScheme,
    ThemeState themeState,
  ) {
    final extended = width >= largeWidthBreakpoint;

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: _onDestinationSelected,
            extended: extended,
            minWidth: 72,
            minExtendedWidth: 200,
            leading: _buildLogo(extended, colorScheme),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildThemeControls(extended, themeState, colorScheme),
                ),
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.flight_outlined),
                selectedIcon: Icon(Icons.flight),
                label: Text('Proxy'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.terminal_outlined),
                selectedIcon: Icon(Icons.terminal),
                label: Text('Logs'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(child: _buildPage()),
        ],
      ),
    );
  }

  Widget _buildLogo(bool extended, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primaryContainer,
            ),
            child: Icon(
              Icons.public,
              color: colorScheme.onPrimaryContainer,
              size: 28,
            ),
          ),
          if (extended) ...[
            const SizedBox(height: 8),
            Text(
              'Proxy UI',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildThemeControls(
    bool extended,
    ThemeState themeState,
    ColorScheme colorScheme,
  ) {
    final colors = ThemeColors.get(themeState.appTheme);

    if (extended) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.tonalIcon(
            onPressed: themeState.nextTheme,
            icon: Icon(colors.icon, size: 18),
            label: Text(colors.name),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: themeState.toggleMode,
            icon: Icon(
              themeState.isDark ? Icons.dark_mode : Icons.light_mode,
              size: 18,
            ),
            label: Text(themeState.isDark ? 'Dark' : 'Light'),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: themeState.nextTheme,
          icon: Icon(colors.icon),
          tooltip: colors.name,
        ),
        const SizedBox(height: 8),
        IconButton.outlined(
          onPressed: themeState.toggleMode,
          icon: Icon(themeState.isDark ? Icons.dark_mode : Icons.light_mode),
          tooltip: themeState.isDark ? 'Dark mode' : 'Light mode',
        ),
      ],
    );
  }
}

class _ThemeSheet extends StatelessWidget {
  final ThemeState themeState;

  const _ThemeSheet({required this.themeState});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 24),
            Text('Theme', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: AppTheme.values.map((theme) {
                final colors = ThemeColors.get(theme);
                final isSelected = themeState.appTheme == theme;
                return FilterChip(
                  selected: isSelected,
                  label: Text(colors.name),
                  avatar: Icon(colors.icon, size: 18),
                  onSelected: (_) => themeState.setTheme(theme),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            Text('Mode', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode),
                ),
              ],
              selected: {themeState.isDark},
              onSelectionChanged: (selected) {
                if (selected.first != themeState.isDark) {
                  themeState.toggleMode();
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}
