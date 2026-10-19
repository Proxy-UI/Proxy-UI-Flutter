import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/country_atlas.dart';
import '../../models/node_filter.dart';
import '../../models/node_group_model.dart';
import '../../models/node_health.dart';
import '../../models/node_model.dart';
import '../../providers/proxy_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/node_badges.dart';
import '../../widgets/planet_glyph.dart';
import 'control_server_dialog.dart';
import 'galaxy/galaxy_canvas.dart';
import 'galaxy/galaxy_model.dart';
import 'galaxy/galaxy_painter.dart';
import 'node_actions.dart';
import 'node_details_panel.dart';
import 'node_list_view.dart';

enum NodesView { galaxy, list }

final _galaxyTexts = Expando<GalaxyText>();

/// The words the galaxy writes on the sky, in the current language.
GalaxyText galaxyTextFor(BuildContext context) {
  final language = Localizations.localeOf(context).languageCode;
  final strings = context.l10n;
  // Keep text identity stable across unrelated provider updates, so rebuilding
  // the surrounding page does not invalidate a resting map's paint or labels.
  return _galaxyTexts[strings] ??= GalaxyText(
    home: strings.galaxyHome,
    unlocated: strings.galaxyUnlocated,
    countryName: (code) => countryName(code, language),
    countryStats: strings.galaxyCountryStats,
  );
}

/// The node catalogue: a galaxy of countries by default, a list on request.
///
/// Both views show the same filtered nodes and share one selection, so
/// switching views keeps what the user was looking at.
class NodesPage extends StatefulWidget {
  const NodesPage({super.key, this.initialSelection});

  /// A body to select on arrival, such as the current node when the
  /// dashboard opens the map.
  final String? initialSelection;

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final TextEditingController _search = TextEditingController();
  final GalaxyController _galaxy = GalaxyController();
  late final NodeActions _actions = NodeActions(context.read<ProxyState>());
  NodesView? _view;
  NodeHealthFilter _filter = NodeHealthFilter.all;
  String? _group;
  String? _selected;

  /// The scene built from the whole catalogue: positions come from here, so
  /// filtering never moves a country.
  GalaxyScene _full = GalaxyScene.empty;
  GalaxyScene _shown = GalaxyScene.empty;
  Object? _sceneKey;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialSelection;
  }

  @override
  void dispose() {
    _search.dispose();
    _actions.dispose();
    super.dispose();
  }

  /// Rebuild the scenes when anything they show has changed.
  void _sync(ProxyState state) {
    final nodes = galaxyNodesOf(state);
    final key = Object.hashAll([
      for (final node in nodes)
        Object.hash(
          node.id,
          node.country,
          node.health,
          node.current,
          node.latencyMs,
        ),
      _search.text,
      _filter,
      _group,
      state.isRunning,
      Object.hashAll(state.groups.map((g) => g.groupId)),
    ]);
    if (key == _sceneKey) return;
    _sceneKey = key;
    _full = buildGalaxyScene(nodes, connected: state.isRunning);
    final matching = filterNodeCatalog(
      nodes: state.nodes,
      groups: state.groups,
      selectedGroupId: _group,
      query: _search.text,
      countryOf: state.effectiveCountry,
    ).map((node) => node.storageKey).toSet();
    _shown = filterGalaxyScene(
      _full,
      (node) => matching.contains(node.id) && _filter.keeps(node.health),
    );
    final selected = _selected;
    if (selected != null &&
        selected != homeId &&
        _full.systemOf(selected) == null &&
        _full.planetOf(selected) == null) {
      _selected = null;
    }
  }

  void _select(String? id) {
    if (id == _selected) return;
    setState(() => _selected = id);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    if (_group != null && !state.groups.any((g) => g.groupId == _group)) {
      _group = null;
    }
    _sync(state);
    final view =
        _view ??
        (MediaQuery.accessibleNavigationOf(context)
            ? NodesView.list
            : NodesView.galaxy);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        return view == NodesView.galaxy
            ? _buildGalaxy(context, state, wide, constraints)
            : _buildList(context, state, wide);
      },
    );
  }

  Widget _toolbar(ProxyState state, NodesView view, bool wide) {
    return _Toolbar(
      search: _search,
      onSearch: () => setState(() {}),
      filter: _filter,
      onFilter: (filter) => setState(() => _filter = filter),
      counts: _healthCounts(),
      view: view,
      onView: (next) => setState(() => _view = next),
      groups: state.groups,
      group: _group,
      onGroup: (group) => setState(() => _group = group),
      actions: _actions,
      shownNodes: [for (final planet in _shown.planets) planet.node.node],
      loading: state.isLoadingNodes,
      onRefresh: state.nodesServerHost.isEmpty
          ? () => ControlServerDialog.show(context)
          : state.fetchNodes,
      wide: wide,
      floating: view == NodesView.galaxy,
    );
  }

  Map<NodeHealth, int> _healthCounts() {
    final counts = <NodeHealth, int>{};
    for (final planet in _full.planets) {
      counts.update(planet.node.health, (n) => n + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  Widget _panel(BuildContext context, {ScrollController? scroll}) {
    final selected = _selected!;
    return NodeDetailsPanel(
      key: ValueKey('panel-$selected'),
      scene: _full,
      selected: selected,
      actions: _actions,
      onSelect: _select,
      onClose: () => _select(null),
      scrollController: scroll,
    );
  }

  Widget _buildGalaxy(
    BuildContext context,
    ProxyState state,
    bool wide,
    BoxConstraints constraints,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Only nodes that were never tested can be located by testing them; an
    // unreachable node has no egress to find.
    final untestedUnlocated = [
      for (final planet
          in _full.systemOf(systemIdFor(''))?.planets ?? const <NodePlanet>[])
        if (planet.node.health == NodeHealth.untested) planet.node.node,
    ];
    final panelOpen = _selected != null;
    const toolbarHeight = 64.0;
    final panelTop = wide ? toolbarHeight + 28 : null;
    return ClipRect(
      child: Stack(
        children: [
          Positioned.fill(
            child: GalaxyCanvas(
              scene: _shown,
              text: galaxyTextFor(context),
              selected: _selected,
              onSelect: _select,
              controller: _galaxy,
              semanticLabel: context.l10n.galaxySemantics,
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _toolbar(state, NodesView.galaxy, wide),
                if (untestedUnlocated.isNotEmpty &&
                    !_actions.testingMany &&
                    state.nodes.isNotEmpty &&
                    !(panelOpen && !wide))
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: _UnlocatedBanner(
                        count: untestedUnlocated.length,
                        onTest: () =>
                            _actions.testMany(context, untestedUnlocated),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (state.nodes.isEmpty)
            Center(
              child: _EmptyState(
                loading: state.isLoadingNodes,
                error: state.nodesError,
              ),
            )
          else if (_shown.isEmpty)
            Center(
              child: Text(
                context.l10n.noNodesMatch(_search.text.trim()),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          if (wide && state.nodes.isNotEmpty)
            Positioned(
              left: 16,
              bottom: 16,
              child: _Legend(counts: _healthCounts()),
            ),
          Positioned(
            right: wide && panelOpen ? 16 + 380 + 12 : 16,
            bottom: !wide && panelOpen ? constraints.maxHeight * 0.5 + 16 : 16,
            child: _RecenterButton(controller: _galaxy),
          ),
          Positioned(
            top: panelTop,
            right: wide ? 16 : 8,
            left: wide ? null : 8,
            bottom: wide ? 16 : 8,
            width: wide ? 380 : null,
            height: wide ? null : constraints.maxHeight * 0.5,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // The panel hangs from the toolbar on a wide window and rests
              // on the bottom edge on a phone, however tall its content.
              layoutBuilder: (current, previous) => Stack(
                alignment: wide ? Alignment.topCenter : Alignment.bottomCenter,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: wide ? const Offset(0.06, 0) : const Offset(0, 0.08),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: panelOpen
                  ? _PanelSurface(
                      key: ValueKey('panel-frame-$_selected'),
                      child: _panel(context),
                    )
                  : const SizedBox.shrink(key: ValueKey('panel-closed')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, ProxyState state, bool wide) {
    final order = {
      for (var i = 0; i < state.nodes.length; i++) state.nodes[i].storageKey: i,
    };
    final list = state.nodes.isEmpty
        ? Center(
            child: _EmptyState(
              loading: state.isLoadingNodes,
              error: state.nodesError,
            ),
          )
        : _shown.isEmpty
        ? Center(child: Text(context.l10n.noNodesMatch(_search.text.trim())))
        : NodeListView(
            scene: _shown,
            order: order,
            sortByLatency: state.sortNodesByLatency,
            selected: _selected,
            actions: _actions,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            onSelect: (id) {
              if (wide) {
                _select(id);
              } else {
                _showSheet(context, id);
              }
            },
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: _toolbar(state, NodesView.list, wide),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: list),
              if (wide && _selected != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 16, 16),
                  child: SizedBox(
                    width: 380,
                    child: _PanelSurface(child: _panel(context)),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showSheet(BuildContext context, String id) async {
    setState(() => _selected = id);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (context, scroll) => StatefulBuilder(
          builder: (context, setSheet) => NodeDetailsPanel(
            scene: _full,
            selected: _selected ?? id,
            actions: _actions,
            scrollController: scroll,
            onSelect: (next) {
              setState(() => _selected = next);
              setSheet(() {});
            },
            onClose: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _selected = null);
  }
}

/// The surface the details panel floats on.
class _PanelSurface extends StatelessWidget {
  const _PanelSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.search,
    required this.onSearch,
    required this.filter,
    required this.onFilter,
    required this.counts,
    required this.view,
    required this.onView,
    required this.groups,
    required this.group,
    required this.onGroup,
    required this.actions,
    required this.shownNodes,
    required this.loading,
    required this.onRefresh,
    required this.wide,
    required this.floating,
  });

  final TextEditingController search;
  final VoidCallback onSearch;
  final NodeHealthFilter filter;
  final ValueChanged<NodeHealthFilter> onFilter;
  final Map<NodeHealth, int> counts;
  final NodesView view;
  final ValueChanged<NodesView> onView;
  final List<NodeGroupModel> groups;
  final String? group;
  final ValueChanged<String?> onGroup;
  final NodeActions actions;
  final List<NodeInfo> shownNodes;
  final bool loading;
  final VoidCallback onRefresh;
  final bool wide;
  final bool floating;

  int _count(NodeHealthFilter filter) {
    var total = 0;
    for (final entry in counts.entries) {
      if (filter.keeps(entry.key)) total += entry.value;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.l10n;
    final field = SearchBar(
      key: const Key('nodes-search'),
      controller: search,
      onChanged: (_) => onSearch(),
      hintText: strings.nodesSearchHint,
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStatePropertyAll(
        scheme.surfaceContainerHighest.withValues(alpha: floating ? 0.7 : 1),
      ),
      constraints: const BoxConstraints(minHeight: 44, maxHeight: 44),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14),
      ),
      leading: Icon(Icons.search, color: scheme.onSurfaceVariant),
      trailing: [
        if (search.text.isNotEmpty)
          IconButton(
            tooltip: strings.clearSearch,
            onPressed: () {
              search.clear();
              onSearch();
            },
            icon: const Icon(Icons.close),
          ),
      ],
    );
    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final option in NodeHealthFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                showCheckmark: false,
                selected: filter == option,
                onSelected: (_) => onFilter(option),
                label: Text(
                  '${switch (option) {
                    NodeHealthFilter.all => strings.all2,
                    NodeHealthFilter.available => strings.filterAvailable,
                    NodeHealthFilter.unreachable => strings.healthUnreachable,
                    NodeHealthFilter.untested => strings.healthUntested,
                  }} ${_count(option)}',
                ),
              ),
            ),
          if (groups.isNotEmpty)
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  onPressed: () => onGroup(null),
                  leadingIcon: Icon(
                    group == null ? Icons.check : Icons.workspaces_outline,
                  ),
                  child: Text(strings.allGroups),
                ),
                for (final g in groups)
                  MenuItemButton(
                    onPressed: () => onGroup(g.groupId),
                    leadingIcon: Icon(
                      group == g.groupId
                          ? Icons.check
                          : Icons.workspaces_outline,
                    ),
                    child: Text('${g.name} (${g.nodeIds.length})'),
                  ),
              ],
              builder: (context, controller, _) => FilterChip(
                showCheckmark: false,
                selected: group != null,
                avatar: const Icon(Icons.workspaces_outline, size: 18),
                label: Text(
                  group == null
                      ? strings.groups
                      : groups.firstWhere((g) => g.groupId == group).name,
                ),
                onSelected: (_) =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
        ],
      ),
    );
    final toggle = SegmentedButton<NodesView>(
      key: const Key('nodes-view-toggle'),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(
          value: NodesView.galaxy,
          icon: const Icon(Icons.blur_circular, size: 18),
          label: wide ? Text(strings.nodesViewGalaxy) : null,
          tooltip: strings.nodesViewGalaxy,
        ),
        ButtonSegment(
          value: NodesView.list,
          icon: const Icon(Icons.view_agenda_outlined, size: 18),
          label: wide ? Text(strings.nodesViewList) : null,
          tooltip: strings.nodesViewList,
        ),
      ],
      selected: {view},
      onSelectionChanged: (next) => onView(next.first),
    );
    final buttons = ListenableBuilder(
      listenable: actions,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: strings.testAll,
            onPressed: actions.testingMany || shownNodes.isEmpty
                ? null
                : () => actions.testMany(context, shownNodes),
            icon: actions.testingMany
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.network_check),
          ),
          // Where the catalogue comes from and how the list is ordered are
          // occasional choices; one menu holds them.
          Consumer<ProxyState>(
            builder: (context, state, _) => MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.refresh),
                  onPressed: loading ? null : onRefresh,
                  child: Text(strings.refreshCatalogue),
                ),
                MenuItemButton(
                  key: const Key('control-server-settings'),
                  leadingIcon: const Icon(Icons.hub_outlined),
                  onPressed: () => ControlServerDialog.show(context),
                  child: Text(strings.controlServerSettings),
                ),
                if (view == NodesView.list)
                  CheckboxMenuButton(
                    value: state.sortNodesByLatency,
                    onChanged: (value) =>
                        state.setSortNodesByLatency(value ?? false),
                    child: Text(strings.sortNodes),
                  ),
              ],
              builder: (context, controller, _) => IconButton(
                key: const Key('nodes-menu'),
                tooltip: strings.options,
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.more_vert),
              ),
            ),
          ),
        ],
      ),
    );
    final content = wide
        ? Row(
            children: [
              SizedBox(width: 300, child: field),
              const SizedBox(width: 12),
              Expanded(child: filters),
              const SizedBox(width: 8),
              toggle,
              const SizedBox(width: 4),
              buttons,
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: 8),
                  toggle,
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: filters),
                  buttons,
                ],
              ),
            ],
          );
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.all(10), child: content),
        if (loading) const LinearProgressIndicator(minHeight: 2),
      ],
    );
    if (!floating) return body;
    return Material(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.94),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      surfaceTintColor: Colors.transparent,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

class _UnlocatedBanner extends StatelessWidget {
  const _UnlocatedBanner({required this.count, required this.onTest});

  final int count;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(Icons.travel_explore, color: scheme.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  context.l10n.unlocatedBanner(count),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
              TextButton(onPressed: onTest, child: Text(context.l10n.testNow)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.loading, required this.error});

  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (loading) return const CircularProgressIndicator();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Card(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.94),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                error == null ? Icons.blur_on : Icons.cloud_off,
                size: 48,
                color: error == null ? scheme.primary : scheme.error,
              ),
              const SizedBox(height: 12),
              Text(
                context.l10n.noNodesAvailable,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                error == null
                    ? context.l10n.noNodesHint
                    : context.l10n.error(error!),
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: error == null ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => ControlServerDialog.show(context),
                icon: const Icon(Icons.hub_outlined),
                label: Text(context.l10n.setUpControlServer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the colours mean, with how many nodes are in each state.
class _Legend extends StatelessWidget {
  const _Legend({required this.counts});

  final Map<NodeHealth, int> counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = StatusColors.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget entry(Widget glyph, String label) => Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          glyph,
          const SizedBox(width: 4),
          Text(label, style: style),
        ],
      ),
    );
    return ExcludeSemantics(
      child: Material(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 2, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final health in NodeHealth.displayOrder)
                    if (health != NodeHealth.testing ||
                        (counts[health] ?? 0) > 0)
                      entry(
                        PlanetGlyph(
                          color: status.health(health, scheme),
                          size: 14,
                        ),
                        '${healthLabel(context, health)} ${counts[health] ?? 0}',
                      ),
                  entry(
                    PlanetGlyph(color: scheme.primary, size: 16, ring: true),
                    context.l10n.nodeInUse,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.galaxyHint,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back to the whole galaxy. Zooming itself is the wheel, a pinch or the
/// +/- keys, so it needs no buttons of its own.
class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.controller});

  final GalaxyController controller;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.small(
      key: const Key('galaxy-reset'),
      heroTag: null,
      tooltip: context.l10n.resetView,
      elevation: 2,
      onPressed: controller.reset,
      child: const Icon(Icons.center_focus_strong_outlined),
    );
  }
}
