import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../constants.dart';
import '../providers/theme_provider.dart';
import 'theme_transition.dart';

/// The light/dark switch. It flips what is on screen, so the first press out
/// of following the system always does the visible thing, and the new theme
/// spreads from the button.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final still = MediaQuery.disableAnimationsOf(context);
    return IconButton(
      key: const Key('theme-toggle'),
      tooltip: context.l10n.toggleBrightness,
      // The window changes under a reveal; an icon that jumped would be the
      // one thing in it that did not move.
      icon: AnimatedSwitcher(
        duration: still ? Duration.zero : const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => RotationTransition(
          turns: Tween(begin: 0.75, end: 1.0).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: Icon(
          dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
          key: ValueKey(dark),
        ),
      ),
      onPressed: () => ThemeTransition.run(
        context,
        () => context.read<ThemeState>().setThemeMode(
          dark ? ThemeMode.light : ThemeMode.dark,
        ),
      ),
    );
  }
}

/// The seed colour the whole palette is generated from.
class ColorSeedMenu extends StatelessWidget {
  const ColorSeedMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeState>();
    return MenuAnchor(
      menuChildren: [
        for (final seed in ColorSeed.values)
          MenuItemButton(
            leadingIcon: Icon(
              seed == theme.colorSeed ? Icons.circle : Icons.circle_outlined,
              color: seed.color,
            ),
            onPressed: seed == theme.colorSeed
                ? null
                : () => ThemeTransition.run(
                    context,
                    () => theme.setColorSeed(seed),
                  ),
            child: Text(seed.label),
          ),
      ],
      builder: (context, controller, _) => IconButton(
        key: const Key('color-seed'),
        tooltip: context.l10n.selectASeedColor,
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.palette_outlined),
      ),
    );
  }
}
