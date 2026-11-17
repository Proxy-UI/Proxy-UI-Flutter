import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/node_model.dart';
import '../models/upstream_endpoint.dart';
import '../models/website_rule.dart';
import '../providers/proxy_provider.dart';

class WebsiteRulesPage extends StatefulWidget {
  const WebsiteRulesPage({super.key});
  @override
  State<WebsiteRulesPage> createState() => _WebsiteRulesPageState();
}

class _WebsiteRulesPageState extends State<WebsiteRulesPage> {
  String? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<ProxyState>().lookUpQuicSupport();
        _reload();
      }
    });
  }

  Future<void> _reload() async {
    final result = await context.read<ProxyState>().manageWebsiteRule();
    if (mounted) {
      setState(() {
        error = result['Err'] as String?;
        loading = false;
      });
    }
  }

  Future<void> _edit([WebsiteRule? rule]) => showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<ProxyState>(),
      child: _RuleEditor(rule: rule),
    ),
  );

  Future<void> _remove(WebsiteRule rule) async {
    final strings = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.websiteRemove),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(rule.site),
            const SizedBox(height: 8),
            Text(strings.websiteRemoveHint),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.websiteRemove),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await context.read<ProxyState>().manageWebsiteRule(
      site: rule.site,
    );
    if (mounted) setState(() => error = result['Err'] as String?);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ProxyState>();
    final strings = context.l10n;
    final theme = Theme.of(context);
    final rules = state.websiteRules;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.websiteRules,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: state.websiteRulesBusy ? null : () => _edit(),
                    icon: const Icon(Icons.add),
                    label: Text(strings.websiteAdd),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(strings.websiteRulesHint),
              const SizedBox(height: 20),
              if (error != null)
                ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text(strings.websiteStoreError),
                  trailing: TextButton(
                    onPressed: _reload,
                    child: Text(strings.retry),
                  ),
                ),
              if (loading)
                const LinearProgressIndicator()
              else if (rules.isEmpty && error == null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Text(
                      strings.websiteEmpty,
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              else if (rules.isNotEmpty)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final (index, rule) in rules.indexed) ...[
                        if (index > 0) const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.secondaryContainer,
                                child: Icon(
                                  rule.endpoint == null
                                      ? Icons.call_made
                                      : Icons.dns_outlined,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      rule.site,
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      rule.endpoint == null
                                          ? strings.websiteDirect
                                          : '${rule.nodeId} · ${rule.endpoint!.transport.label} · ${rule.endpoint!.address}',
                                      style: theme.textTheme.bodySmall,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: strings.websiteEdit,
                                onPressed: state.websiteRulesBusy
                                    ? null
                                    : () => _edit(rule),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: strings.websiteRemove,
                                onPressed: state.websiteRulesBusy
                                    ? null
                                    : () => _remove(rule),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text(strings.websiteDefault, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({this.rule});
  final WebsiteRule? rule;
  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  late final site = TextEditingController(text: widget.rule?.site);
  late bool direct = widget.rule?.nodeId == null;
  late String? nodeId = widget.rule?.nodeId;
  late UpstreamTransport? carrier = widget.rule?.endpoint?.transport;
  String? error;
  bool saving = false;

  @override
  void dispose() {
    site.dispose();
    super.dispose();
  }

  Future<void> _save(NodeInfo? node, UpstreamTransport? selected) async {
    setState(() {
      saving = true;
      error = null;
    });
    final result = await context.read<ProxyState>().manageWebsiteRule(
      site: site.text.trim(),
      direct: direct,
      nodeId: node?.nodeId,
      transport: selected?.name,
    );
    if (!mounted) return;
    if (result.containsKey('Ok')) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      saving = false;
      error = result['Err'] as String?;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final state = context.watch<ProxyState>();
    final nodes = state.nodes.where((n) => n.endpoint != null).toList();
    final node = nodes.where((n) => n.nodeId == nodeId).firstOrNull;
    final carriers = [
      for (final c in UpstreamTransport.values)
        if (node != null && state.endpointOf(node, c) != null) c,
    ];
    final selected = carrier == null
        ? carriers.firstOrNull
        : carriers.where((c) => c == carrier).firstOrNull;
    return AlertDialog(
      title: Text(
        widget.rule == null ? strings.websiteAdd : strings.websiteEdit,
      ),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: site,
              readOnly: widget.rule != null,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: strings.websiteDomain,
                hintText: '*.example.com:443',
                helperText: strings.websiteMatchHint,
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  icon: const Icon(Icons.call_made),
                  label: Text(strings.websiteDirect),
                ),
                ButtonSegment(
                  value: false,
                  icon: const Icon(Icons.dns_outlined),
                  label: Text(strings.websiteNode),
                ),
              ],
              selected: {direct},
              onSelectionChanged: saving
                  ? null
                  : (v) => setState(() => direct = v.first),
            ),
            if (!direct) ...[
              const SizedBox(height: 20),
              if (nodes.isEmpty)
                Text(strings.websiteNoNodes)
              else
                DropdownButtonFormField<String>(
                  initialValue: node?.nodeId,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: strings.websiteNode),
                  items: [
                    for (final n in nodes)
                      DropdownMenuItem(
                        value: n.nodeId,
                        child: Text(n.nodeId, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: saving
                      ? null
                      : (value) => setState(() {
                          nodeId = value;
                          carrier = null;
                        }),
                ),
              if (carriers.isNotEmpty) ...[
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final c in carriers)
                      ChoiceChip(
                        label: Text(
                          '${c.label} · ${state.endpointOf(node!, c)!.port}',
                        ),
                        selected: c == selected,
                        onSelected: saving
                            ? null
                            : (_) => setState(() => carrier = c),
                      ),
                  ],
                ),
              ],
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  switch (error) {
                    'invalid_rule' => strings.websiteInvalid,
                    'unknown_node' ||
                    'unsupported_transport' => strings.websiteNoNodes,
                    'busy' => strings.proxyOperationIsAlreadyInProgress,
                    _ => strings.websiteStoreError,
                  },
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(strings.cancel),
        ),
        FilledButton(
          onPressed:
              saving ||
                  site.text.trim().isEmpty ||
                  (!direct && (node == null || selected == null))
              ? null
              : () => _save(node, selected),
          child: Text(strings.save),
        ),
      ],
    );
  }
}
