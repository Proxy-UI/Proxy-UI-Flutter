import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/country_atlas.dart';
import '../models/node_model.dart';
import '../models/upstream_endpoint.dart';
import '../models/website_rule.dart';
import '../providers/proxy_provider.dart';
import '../services/website_rules.dart';
import '../widgets/node_badges.dart';

/// Rules that send chosen websites directly or through one node, ahead of
/// the default route.
class WebsiteRulesPage extends StatefulWidget {
  const WebsiteRulesPage({super.key});

  @override
  State<WebsiteRulesPage> createState() => _WebsiteRulesPageState();
}

class _WebsiteRulesPageState extends State<WebsiteRulesPage> {
  /// Below this many rules a filter field is clutter.
  static const _filterThreshold = 6;
  final _filter = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<ProxyState>();
      // The editor offers a node's QUIC port once the catalogue reported it.
      state.lookUpQuicSupport();
      state.websiteRules.load();
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _edit([WebsiteRule? rule]) {
    final state = context.read<ProxyState>();
    return showDialog<void>(
      context: context,
      builder: (_) => ChangeNotifierProvider.value(
        value: state,
        child: _RuleEditor(rule: rule),
      ),
    );
  }

  Future<void> _remove(WebsiteRule rule) async {
    final strings = context.l10n;
    final rules = context.read<ProxyState>().websiteRules;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: Text(strings.websiteRemoveConfirm(rule.site)),
        content: Text(strings.websiteRemoveHint),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.websiteRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final error = await rules.remove(rule.site);
    if (error != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(strings.websiteStoreError)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final strings = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([state.websiteRules, _filter]),
      builder: (context, _) {
        final store = state.websiteRules;
        final query = _filter.text.trim().toLowerCase();
        final shown = [
          for (final rule in store.rules)
            if (query.isEmpty ||
                _matches(rule, query, state, language, strings))
              rule,
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final addButton = FilledButton.icon(
                        onPressed: store.isBusy ? null : () => _edit(),
                        icon: const Icon(Icons.add),
                        label: Text(strings.websiteAdd),
                      );
                      final heading = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            strings.websiteRules,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            strings.websiteRulesHint,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      );
                      if (constraints.maxWidth < 420) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            heading,
                            const SizedBox(height: 12),
                            addButton,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: heading),
                          const SizedBox(width: 16),
                          addButton,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  if (store.loadError != null)
                    _LoadError(onRetry: store.load)
                  else if (!store.isLoaded)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 48),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (store.rules.isEmpty)
                    _EmptyRules(onAdd: () => _edit())
                  else ...[
                    if (store.rules.length >= _filterThreshold) ...[
                      TextField(
                        controller: _filter,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _filter.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: _filter.clear,
                                ),
                          hintText: strings.websiteFilter,
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (shown.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          strings.websiteNoMatches,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      Card(
                        child: Column(
                          children: [
                            for (final (index, rule) in shown.indexed) ...[
                              if (index > 0)
                                const Divider(indent: 72, endIndent: 16),
                              _RuleRow(
                                rule: rule,
                                enabled: !store.isBusy,
                                onEdit: () => _edit(rule),
                                onRemove: () => _remove(rule),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          strings.websiteFooter,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static bool _matches(
    WebsiteRule rule,
    String query,
    ProxyState state,
    String language,
    AppLocalizations strings,
  ) {
    if (rule.site.toLowerCase().contains(query)) return true;
    return switch (rule.target) {
      DirectTarget() =>
        'direct'.contains(query) ||
            strings.websiteDirect.toLowerCase().contains(query),
      NodeTarget(:final nodeId, :final endpoint) => () {
        if (nodeId.toLowerCase().contains(query) ||
            endpoint.address.toLowerCase().contains(query) ||
            endpoint.transport.name.contains(query)) {
          return true;
        }
        final node = state.nodes.where((n) => n.nodeId == nodeId).firstOrNull;
        if (node == null) return false;
        final code = state.effectiveCountry(node);
        return code.toLowerCase().contains(query) ||
            node.region.toLowerCase().contains(query) ||
            (code.isNotEmpty &&
                countryName(code, language).toLowerCase().contains(query));
      }(),
    };
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.rule,
    required this.enabled,
    required this.onEdit,
    required this.onRemove,
  });

  final WebsiteRule rule;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final strings = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final target = rule.target;
    final node = switch (target) {
      DirectTarget() => null,
      NodeTarget(:final nodeId) =>
        state.nodes.where((n) => n.nodeId == nodeId).firstOrNull,
    };
    final warning = _staleness(context, state, target, node);
    return InkWell(
      onTap: enabled ? onEdit : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            _RouteBadge(target: target, node: node),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            if (rule.coversSubdomains)
                              TextSpan(
                                text: '*.',
                                style: TextStyle(color: scheme.primary),
                              ),
                            TextSpan(text: rule.host),
                          ],
                        ),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (rule.coversSubdomains)
                        _ScopeTag(strings.websiteSubdomains),
                      if (rule.port case final port?)
                        _ScopeTag(strings.websitePort(port.toString())),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.subdirectory_arrow_right,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _routeSummary(state, language, strings, target, node),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      if (target case NodeTarget(:final endpoint)
                          when endpoint.isQuic) ...[
                        const SizedBox(width: 6),
                        ProtocolTag(endpoint.transport.label),
                      ],
                    ],
                  ),
                  if (warning != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 16,
                          color: scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            warning,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: strings.websiteEdit,
              onPressed: enabled ? onEdit : null,
              icon: const Icon(Icons.edit_outlined, size: 20),
            ),
            IconButton(
              tooltip: strings.websiteRemove,
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  /// Avoids printing two `host:port` addresses side by side when `nodeId` is
  /// itself the node's TCP address while the rule uses its QUIC port.
  static String _routeSummary(
    ProxyState state,
    String language,
    AppLocalizations strings,
    RuleTarget target,
    NodeInfo? node,
  ) => switch (target) {
    DirectTarget() => strings.websiteDirect,
    NodeTarget(:final nodeId, :final endpoint) => () {
      final code = node == null ? '' : state.effectiveCountry(node);
      final place = code.isEmpty ? '' : countryName(code, language);
      final idHost = UpstreamEndpoint.tryParse(nodeId)?.host.toLowerCase();
      final customId = idHost != endpoint.host.toLowerCase();
      return [
        if (place.isNotEmpty) place,
        if (customId) nodeId,
        endpoint.address,
        if (!endpoint.isQuic) endpoint.transport.label,
      ].join(' · ');
    }(),
  };

  /// Why a node rule may no longer go where the catalogue says, if it may.
  /// Says nothing while the catalogue is not loaded or a port is unknown.
  static String? _staleness(
    BuildContext context,
    ProxyState state,
    RuleTarget target,
    NodeInfo? node,
  ) {
    if (target is! NodeTarget || state.nodes.isEmpty) return null;
    if (node == null) return context.l10n.websiteNodeMissing;
    final current = state.endpointOf(node, target.endpoint.transport);
    if (current == null ||
        (current.host.toLowerCase() == target.endpoint.host.toLowerCase() &&
            current.port == target.endpoint.port)) {
      return null;
    }
    return context.l10n.websiteEndpointChanged(current.address);
  }
}

/// A rule's route at a glance: an arrow for direct, the node's flag otherwise.
class _RouteBadge extends StatelessWidget {
  const _RouteBadge({required this.target, required this.node});

  final RuleTarget target;
  final NodeInfo? node;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (target) {
      DirectTarget() => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      NodeTarget() => (scheme.primaryContainer, scheme.onPrimaryContainer),
    };
    final node = this.node;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: switch (target) {
        DirectTarget() => Icon(Icons.near_me_outlined, color: foreground),
        NodeTarget() when node != null => CountryFlagBadge(
          code: context.read<ProxyState>().effectiveCountry(node),
        ),
        NodeTarget() => Icon(Icons.hub_outlined, color: foreground),
      },
    );
  }
}

class _ScopeTag extends StatelessWidget {
  const _ScopeTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: scheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.alt_route,
                size: 32,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              strings.websiteEmpty,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                strings.websiteEmptyHint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: Text(strings.websiteAdd),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.l10n.websiteLoadError,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(context.l10n.retry)),
          ],
        ),
      ),
    );
  }
}

enum _Route { direct, node }

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({this.rule});

  final WebsiteRule? rule;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final _site = TextEditingController(text: widget.rule?.site);
  late _Route _route = widget.rule?.target is NodeTarget
      ? _Route.node
      : _Route.direct;
  late String? _nodeId = switch (widget.rule?.target) {
    NodeTarget(:final nodeId) => nodeId,
    _ => null,
  };
  late UpstreamTransport? _transport = switch (widget.rule?.target) {
    NodeTarget(:final endpoint) => endpoint.transport,
    _ => null,
  };
  WebsiteRuleError? _error;
  bool _saving = false;

  bool get _editing => widget.rule != null;

  bool get _coversSubdomains {
    final text = _site.text.trim();
    final afterScheme = switch (text.indexOf('://')) {
      -1 => text,
      final index => text.substring(index + 3),
    };
    return afterScheme.startsWith('*.');
  }

  void _toggleSubdomains(bool enabled) {
    final trimmed = _site.text.trim();
    String updated;
    if (trimmed.isEmpty) {
      updated = enabled ? '*.' : '';
    } else if (trimmed.indexOf('://') case final schemeIndex
        when schemeIndex >= 0) {
      final prefix = trimmed.substring(0, schemeIndex + 3);
      final rest = trimmed.substring(schemeIndex + 3);
      if (enabled && !rest.startsWith('*.')) {
        updated = '$prefix*.$rest';
      } else if (!enabled && rest.startsWith('*.')) {
        updated = '$prefix${rest.substring(2)}';
      } else {
        updated = trimmed;
      }
    } else if (enabled && !trimmed.startsWith('*.')) {
      updated = '*.$trimmed';
    } else if (!enabled && trimmed.startsWith('*.')) {
      updated = trimmed.substring(2);
    } else {
      updated = trimmed;
    }
    setState(() {
      _site.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
      if (_error == WebsiteRuleError.invalidRule) _error = null;
    });
  }

  @override
  void dispose() {
    _site.dispose();
    super.dispose();
  }

  Future<void> _save(RuleTarget target) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await context.read<ProxyState>().websiteRules.save(
      _site.text.trim(),
      target,
      previous: widget.rule?.site,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<ProxyState>();
    final nodes = [
      for (final node in state.nodes)
        if (state.endpointsOf(node).isNotEmpty) node,
    ];
    final node = nodes.where((n) => n.nodeId == _nodeId).firstOrNull;
    final endpoints = node == null
        ? const <UpstreamEndpoint>[]
        : state.endpointsOf(node);
    final endpoint =
        endpoints.where((e) => e.transport == _transport).firstOrNull ??
        endpoints.firstOrNull;
    final RuleTarget? target = switch (_route) {
      _Route.direct => const DirectTarget(),
      _Route.node when node != null && endpoint != null => NodeTarget(
        node.nodeId,
        endpoint,
      ),
      _Route.node => switch (widget.rule?.target) {
        final NodeTarget pinned when pinned.nodeId == _nodeId => pinned,
        _ => null,
      },
    };
    final compactDialog = MediaQuery.sizeOf(context).width < 460;
    final directOption = _RouteOption(
      icon: Icons.near_me_outlined,
      title: strings.websiteDirect,
      subtitle: strings.websiteDirectHint,
      selected: _route == _Route.direct,
      onTap: _saving ? null : () => setState(() => _route = _Route.direct),
    );
    final nodeOption = _RouteOption(
      icon: Icons.hub_outlined,
      title: strings.websiteNode,
      subtitle: strings.websiteNodeHint,
      selected: _route == _Route.node,
      onTap: _saving ? null : () => setState(() => _route = _Route.node),
    );
    final siteText = _site.text.trim();
    final canSave =
        !_saving && siteText.isNotEmpty && siteText != '*.' && target != null;
    final inputFill = scheme.brightness == Brightness.dark
        ? scheme.surfaceContainer
        : scheme.surfaceContainerLowest;
    final dialogTheme = theme.copyWith(
      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: inputFill,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
    return Theme(
      data: dialogTheme,
      child: AlertDialog(
        title: Text(_editing ? strings.websiteEdit : strings.websiteAdd),
        scrollable: true,
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _site,
                autofocus: !_editing,
                enabled: !_saving,
                onChanged: (_) => setState(() {
                  if (_error == WebsiteRuleError.invalidRule) _error = null;
                }),
                onSubmitted: canSave ? (_) => _save(target) : null,
                decoration: InputDecoration(
                  labelText: strings.websiteSite,
                  hintText: '*.example.com:443',
                  prefixIcon: const Icon(Icons.language),
                  helperText: strings.websiteSiteHint,
                  helperMaxLines: 3,
                  errorText: _error == WebsiteRuleError.invalidRule
                      ? strings.websiteInvalid
                      : null,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilterChip(
                  label: Text('*. ${strings.websiteSubdomains}'),
                  selected: _coversSubdomains,
                  visualDensity: VisualDensity.compact,
                  onSelected: _saving ? null : _toggleSubdomains,
                ),
              ),
              const SizedBox(height: 18),
              Text(strings.websiteRoute, style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              if (compactDialog)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    directOption,
                    const SizedBox(height: 10),
                    nodeOption,
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(child: directOption),
                    const SizedBox(width: 12),
                    Expanded(child: nodeOption),
                  ],
                ),
              if (_route == _Route.node) ...[
                const SizedBox(height: 20),
                if (nodes.isEmpty)
                  Text(
                    strings.websiteNoNodes,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else ...[
                  DropdownMenu<String>(
                    initialSelection: node?.nodeId,
                    enabled: !_saving,
                    expandedInsets: EdgeInsets.zero,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    menuHeight: 320,
                    label: Text(strings.websiteChooseNode),
                    leadingIcon: node == null
                        ? const Icon(Icons.hub_outlined)
                        : Padding(
                            padding: const EdgeInsets.all(12),
                            child: CountryFlagBadge(
                              code: state.effectiveCountry(node),
                              size: 22,
                            ),
                          ),
                    dropdownMenuEntries: [
                      for (final n in nodes)
                        DropdownMenuEntry(
                          value: n.nodeId,
                          label: n.nodeId,
                          leadingIcon: CountryFlagBadge(
                            code: state.effectiveCountry(n),
                            size: 20,
                          ),
                          trailingIcon: _NodeEntryMeta(
                            country: state.effectiveCountry(n),
                            language: language,
                            hasQuic: state.endpointsOf(n).any((e) => e.isQuic),
                          ),
                        ),
                    ],
                    onSelected: (id) => setState(() {
                      _nodeId = id;
                      _transport = null;
                    }),
                  ),
                  if (endpoints.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      strings.websiteTransport,
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in endpoints)
                          ChoiceChip(
                            label: Text('${e.transport.label} · ${e.port}'),
                            selected: e.transport == endpoint?.transport,
                            onSelected: _saving
                                ? null
                                : (_) =>
                                      setState(() => _transport = e.transport),
                          ),
                      ],
                    ),
                  ],
                ],
              ],
              if (target case NodeTarget(:final endpoint)) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Icon(Icons.route, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.websiteRoutesVia(
                          endpoint.address,
                          endpoint.transport.label,
                        ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error == WebsiteRuleError.storage) ...[
                const SizedBox(height: 16),
                Text(
                  strings.websiteStoreError,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: canSave ? () => _save(target) : null,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(strings.save),
          ),
        ],
      ),
    );
  }
}

class _NodeEntryMeta extends StatelessWidget {
  const _NodeEntryMeta({
    required this.country,
    required this.language,
    required this.hasQuic,
  });

  final String country;
  final String language;
  final bool hasQuic;

  @override
  Widget build(BuildContext context) {
    final place = country.isEmpty ? '' : countryName(country, language);
    if (place.isEmpty && !hasQuic) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (place.isNotEmpty)
          Text(
            place,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        if (place.isNotEmpty && hasQuic) const SizedBox(width: 6),
        if (hasQuic) ProtocolTag(UpstreamTransport.quic.label),
      ],
    );
  }
}

/// One of the two routes a rule can take, drawn as a selectable card.
class _RouteOption extends StatelessWidget {
  const _RouteOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, color: selected ? scheme.primary : foreground),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: selected
                              ? scheme.onSecondaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
