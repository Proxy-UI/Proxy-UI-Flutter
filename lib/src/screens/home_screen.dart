import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/theme_provider.dart';
import '../widgets/app_window_title_bar.dart';
import 'proxy_page.dart';
import 'log_page.dart';
import 'subscription_page.dart';
import 'nodes_page.dart';

/// Main navigation container with responsive layout and smooth transitions
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> scaffoldKey = GlobalKey<ScaffoldState>();
  late final AnimationController controller;
  late final CurvedAnimation railAnimation;

  bool controllerInitialized = false;
  LayoutStatus curLayoutStatus = LayoutStatus.moreSmall;
  int screenIndex = 0;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      duration: Duration(milliseconds: transitionLength.toInt() * 2),
      value: 0,
      vsync: this,
    );
    railAnimation = CurvedAnimation(
      parent: controller,
      curve: const Interval(0.5, 1.0),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final double width = MediaQuery.of(context).size.width;
    final AnimationStatus status = controller.status;

    if (width > mediumWidthBreakpoint) {
      if (width > largeWidthBreakpoint) {
        curLayoutStatus = LayoutStatus.large;
      } else {
        curLayoutStatus = LayoutStatus.medium;
      }
      if (status != AnimationStatus.forward &&
          status != AnimationStatus.completed) {
        controller.forward();
      }
    } else {
      curLayoutStatus = LayoutStatus.small;
      if (status != AnimationStatus.reverse &&
          status != AnimationStatus.dismissed) {
        controller.reverse();
      }
    }

    if (curLayoutStatus == LayoutStatus.small && width < smallWidthBreakpoint) {
      curLayoutStatus = LayoutStatus.moreSmall;
    }

    if (!controllerInitialized) {
      controllerInitialized = true;
      controller.value = width > mediumWidthBreakpoint ? 1 : 0;
    }
  }

  void handleScreenChanged(int index) {
    setState(() => screenIndex = index);
  }

  Widget createScreenFor(int index) {
    return switch (index) {
      0 => ProxyPage(scaffoldKey: scaffoldKey),
      1 => const LogPage(),
      2 => const SubscriptionPage(),
      3 => const NodesPage(),
      _ => ProxyPage(scaffoldKey: scaffoldKey),
    };
  }

  PreferredSizeWidget createAppBar(ThemeState themeState) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    if (isDesktop) {
      return AppWindowTitleBar(
        title: 'Proxy With Flutter',
        actions: curLayoutStatus.index <= LayoutStatus.small.index
            ? [
                _BrightnessButton(themeState: themeState, compact: true),
                _ColorSeedButton(themeState: themeState, compact: true),
              ]
            : const [],
      );
    }
    return AppBar(
      title: Text(
        Platform.isAndroid ? 'Proxy Everything' : 'Proxy With Flutter',
      ),
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Theme.of(context).colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      actions: curLayoutStatus.index <= LayoutStatus.small.index
          ? [
              _BrightnessButton(themeState: themeState),
              _ColorSeedButton(themeState: themeState),
            ]
          : const [],
    );
  }

  Widget _trailingActions(ThemeState themeState) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: _BrightnessButton(
            themeState: themeState,
            showTooltipBelow: false,
          ),
        ),
        Flexible(child: _ColorSeedButton(themeState: themeState)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeState = context.watch<ThemeState>();

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return NavigationTransition(
          scaffoldKey: scaffoldKey,
          animationController: controller,
          railAnimation: railAnimation,
          appBar: createAppBar(themeState),
          body: createScreenFor(screenIndex),
          navigationRail: NavigationRail(
            extended: curLayoutStatus == LayoutStatus.large,
            destinations: navRailDestinations,
            selectedIndex: screenIndex,
            onDestinationSelected: handleScreenChanged,
            trailing: Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: curLayoutStatus == LayoutStatus.large
                    ? _ExpandedTrailingActions(themeState: themeState)
                    : _trailingActions(themeState),
              ),
            ),
          ),
          navigationBar: NavigationBars(
            onSelectItem: handleScreenChanged,
            selectedIndex: screenIndex,
          ),
        );
      },
    );
  }
}

class _BrightnessButton extends StatelessWidget {
  const _BrightnessButton({
    required this.themeState,
    this.showTooltipBelow = true,
    this.compact = false,
  });

  final ThemeState themeState;
  final bool showTooltipBelow;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isBright = Theme.of(context).brightness == Brightness.light;
    return Tooltip(
      preferBelow: showTooltipBelow,
      message: 'Toggle brightness',
      child: IconButton(
        icon: isBright
            ? const Icon(Icons.dark_mode_outlined)
            : const Icon(Icons.light_mode_outlined),
        onPressed: themeState.toggleMode,
        visualDensity: compact ? VisualDensity.compact : null,
        constraints: compact
            ? const BoxConstraints.tightFor(width: 40, height: 40)
            : null,
      ),
    );
  }
}

class _ColorSeedButton extends StatelessWidget {
  const _ColorSeedButton({required this.themeState, this.compact = false});

  final ThemeState themeState;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton(
      icon: const Icon(Icons.palette_outlined),
      tooltip: 'Select a seed color',
      padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
      constraints: compact
          ? const BoxConstraints.tightFor(width: 40, height: 40)
          : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (context) {
        return List.generate(ColorSeed.values.length, (index) {
          final currentColor = ColorSeed.values[index];
          return PopupMenuItem(
            value: index,
            enabled: currentColor != themeState.colorSeed,
            child: Wrap(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Icon(
                    currentColor == themeState.colorSeed
                        ? Icons.color_lens
                        : Icons.color_lens_outlined,
                    color: currentColor.color,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 20),
                  child: Text(currentColor.label),
                ),
              ],
            ),
          );
        });
      },
      onSelected: (value) => themeState.setColorSeed(ColorSeed.values[value]),
    );
  }
}

class _ExpandedTrailingActions extends StatelessWidget {
  const _ExpandedTrailingActions({required this.themeState});

  final ThemeState themeState;

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final isBright = Theme.of(context).brightness == Brightness.light;

    final trailingActionsBody = Container(
      constraints: const BoxConstraints.tightFor(width: 250),
      padding: const EdgeInsets.symmetric(horizontal: 30),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Brightness'),
              Expanded(child: Container()),
              Switch(
                value: isBright,
                onChanged: (_) => themeState.toggleMode(),
              ),
            ],
          ),
          const Divider(),
          _ExpandedColorSeedAction(themeState: themeState),
        ],
      ),
    );

    return screenHeight > 740
        ? trailingActionsBody
        : SingleChildScrollView(child: trailingActionsBody);
  }
}

class _ExpandedColorSeedAction extends StatelessWidget {
  const _ExpandedColorSeedAction({required this.themeState});

  final ThemeState themeState;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 200.0),
      child: GridView.count(
        crossAxisCount: 3,
        children: List.generate(
          ColorSeed.values.length,
          (i) => IconButton(
            icon: const Icon(Icons.radio_button_unchecked),
            color: ColorSeed.values[i].color,
            isSelected: themeState.colorSeed == ColorSeed.values[i],
            selectedIcon: const Icon(Icons.circle),
            onPressed: () => themeState.setColorSeed(ColorSeed.values[i]),
            tooltip: ColorSeed.values[i].label,
          ),
        ),
      ),
    );
  }
}

// Navigation destinations
const List<NavigationDestination> appBarDestinations = [
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
  NavigationDestination(
    icon: Icon(Icons.cloud_download_outlined),
    selectedIcon: Icon(Icons.cloud_download),
    label: 'Subscription',
  ),
  NavigationDestination(
    icon: Icon(Icons.dns_outlined),
    selectedIcon: Icon(Icons.dns),
    label: 'Nodes',
  ),
];

final List<NavigationRailDestination> navRailDestinations = appBarDestinations
    .map(
      (destination) => NavigationRailDestination(
        icon: Tooltip(message: destination.label, child: destination.icon),
        selectedIcon: Tooltip(
          message: destination.label,
          child: destination.selectedIcon,
        ),
        label: Text(destination.label),
      ),
    )
    .toList();

class NavigationBars extends StatelessWidget {
  const NavigationBars({
    super.key,
    required this.onSelectItem,
    required this.selectedIndex,
  });

  final void Function(int) onSelectItem;
  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return NavigationBar(
      height: Platform.isAndroid ? 64 : null,
      labelTextStyle: Platform.isAndroid
          ? WidgetStatePropertyAll(Theme.of(context).textTheme.labelSmall)
          : null,
      selectedIndex: selectedIndex,
      onDestinationSelected: onSelectItem,
      destinations: appBarDestinations,
    );
  }
}

class NavigationTransition extends StatefulWidget {
  const NavigationTransition({
    super.key,
    required this.scaffoldKey,
    required this.animationController,
    required this.railAnimation,
    required this.navigationRail,
    required this.navigationBar,
    required this.appBar,
    required this.body,
  });

  final GlobalKey<ScaffoldState> scaffoldKey;
  final AnimationController animationController;
  final CurvedAnimation railAnimation;
  final Widget navigationRail;
  final Widget navigationBar;
  final PreferredSizeWidget appBar;
  final Widget body;

  @override
  State<NavigationTransition> createState() => _NavigationTransitionState();
}

class _NavigationTransitionState extends State<NavigationTransition> {
  late final AnimationController controller;
  late final CurvedAnimation railAnimation;
  late final ReverseAnimation barAnimation;

  @override
  void initState() {
    super.initState();
    controller = widget.animationController;
    railAnimation = widget.railAnimation;
    barAnimation = ReverseAnimation(
      CurvedAnimation(parent: controller, curve: const Interval(0.0, 0.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      key: widget.scaffoldKey,
      appBar: widget.appBar,
      body: Row(
        children: <Widget>[
          RailTransition(
            animation: railAnimation,
            backgroundColor: colorScheme.surface,
            child: widget.navigationRail,
          ),
          Expanded(child: widget.body),
        ],
      ),
      bottomNavigationBar: BarTransition(
        animation: barAnimation,
        backgroundColor: colorScheme.surface,
        child: widget.navigationBar,
      ),
    );
  }
}

class SizeAnimation extends CurvedAnimation {
  SizeAnimation(Animation<double> parent)
    : super(
        parent: parent,
        curve: const Interval(0.2, 0.8, curve: Curves.easeInOutCubicEmphasized),
        reverseCurve: Interval(
          0,
          0.2,
          curve: Curves.easeInOutCubicEmphasized.flipped,
        ),
      );
}

class OffsetAnimation extends CurvedAnimation {
  OffsetAnimation(Animation<double> parent)
    : super(
        parent: parent,
        curve: const Interval(0.4, 1.0, curve: Curves.easeInOutCubicEmphasized),
        reverseCurve: Interval(
          0,
          0.2,
          curve: Curves.easeInOutCubicEmphasized.flipped,
        ),
      );
}

class RailTransition extends StatefulWidget {
  const RailTransition({
    super.key,
    required this.animation,
    required this.backgroundColor,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;
  final Color backgroundColor;

  @override
  State<RailTransition> createState() => _RailTransition();
}

class _RailTransition extends State<RailTransition> {
  late Animation<Offset> offsetAnimation;
  late Animation<double> widthAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final bool ltr = Directionality.of(context) == TextDirection.ltr;

    widthAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(SizeAnimation(widget.animation));

    offsetAnimation = Tween<Offset>(
      begin: ltr ? const Offset(-1, 0) : const Offset(1, 0),
      end: Offset.zero,
    ).animate(OffsetAnimation(widget.animation));
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: DecoratedBox(
        decoration: BoxDecoration(color: widget.backgroundColor),
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: widthAnimation.value,
          child: FractionalTranslation(
            translation: offsetAnimation.value,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class BarTransition extends StatefulWidget {
  const BarTransition({
    super.key,
    required this.animation,
    required this.backgroundColor,
    required this.child,
  });

  final Animation<double> animation;
  final Color backgroundColor;
  final Widget child;

  @override
  State<BarTransition> createState() => _BarTransition();
}

class _BarTransition extends State<BarTransition> {
  late final Animation<Offset> offsetAnimation;
  late final Animation<double> heightAnimation;

  @override
  void initState() {
    super.initState();

    offsetAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(OffsetAnimation(widget.animation));

    heightAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(SizeAnimation(widget.animation));
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: DecoratedBox(
        decoration: BoxDecoration(color: widget.backgroundColor),
        child: Align(
          alignment: Alignment.topLeft,
          heightFactor: heightAnimation.value,
          child: FractionalTranslation(
            translation: offsetAnimation.value,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
