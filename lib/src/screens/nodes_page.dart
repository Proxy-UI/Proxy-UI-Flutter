import 'package:proxy_ui/l10n/app_language.dart';
import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/node_filter.dart';
import '../models/node_model.dart';
import '../providers/proxy_provider.dart';
import '../utils/toast_utils.dart';

/// Nodes page for managing proxy nodes.
class NodesPage extends StatefulWidget {
  const NodesPage({super.key});

  @override
  State<NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<NodesPage> {
  final Map<String, bool> _switchLoading = {};
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _keyController = TextEditingController();
  final _searchController = TextEditingController();
  bool _showConfig = true;
  bool _controlFieldsInitialized = false;
  bool _isTestingAll = false;
  String? _selectedGroupId;
  String _searchQuery = '';
  String? _selectedCountry;

  void _initializeControlFields(ProxyState state) {
    _hostController.text = state.nodesServerHost.isEmpty
        ? state.config.serverHost
        : state.nodesServerHost;
    _portController.text = state.nodesServerPort.toString();
    _keyController.text = state.nodesSessionKey ?? '';
    _controlFieldsInitialized = true;
  }

  void _persistControlFields() {
    context.read<ProxyState>().updateNodesServerConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text),
      sessionKey: _keyController.text.trim(),
    );
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _keyController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchNodes() async {
    final state = context.read<ProxyState>();
    final port = int.tryParse(_portController.text);
    if (port == null || port < 1 || port > 65535) {
      ToastUtils.showError(context.l10n.invalidPortNumber);
      return;
    }

    state.updateNodesServerConfig(
      host: _hostController.text.trim(),
      port: port,
      sessionKey: _keyController.text.trim(),
    );
    await state.fetchNodes();
  }

  Future<void> _onRefresh() async {
    await _fetchNodes();
  }

  Future<void> _exportConfig(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    final state = context.read<ProxyState>();
    try {
      await state.exportNodeConfig(node);
      if (mounted) {
        ToastUtils.showSuccess(strings.configExportedToClipboard);
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(strings.failedToExport((e).toString()));
      }
    }
  }

  Future<void> _switchNode(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    final state = context.read<ProxyState>();
    setState(() => _switchLoading[node.nodeId] = true);

    try {
      final success = await state.switchToNode(node);
      if (mounted) {
        if (success) {
          ToastUtils.showSuccess(
            strings.switchedTo((node.displayName).toString()),
          );
        } else {
          ToastUtils.showError(state.lastError ?? strings.failedToSwitchNode);
        }
      }
    } catch (e) {
      if (mounted) {
        ToastUtils.showError(strings.failedToSwitch((e).toString()));
      }
    } finally {
      if (mounted) {
        setState(() => _switchLoading[node.nodeId] = false);
      }
    }
  }

  Future<void> _testAllNodes(ProxyState state) async {
    if (_isTestingAll) return;
    final nodes = _filterNodes(state);
    if (nodes.isEmpty) return;

    setState(() => _isTestingAll = true);
    var nextIndex = 0;
    var failures = 0;

    Future<void> worker() async {
      while (nextIndex < nodes.length) {
        final node = nodes[nextIndex++];
        final verification = await state.verifyNode(node);
        if (verification == null || !verification.isVerified) failures++;
      }
    }

    final workerCount = nodes.length < 8 ? nodes.length : 8;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (!mounted) return;
    setState(() => _isTestingAll = false);
    if (failures == 0) {
      ToastUtils.showSuccess(
        context.l10n.testedNodes((nodes.length).toString()),
      );
    } else {
      ToastUtils.showError(
        context.l10n.testedReachableFailed(
          (nodes.length).toString(),
          (nodes.length - failures).toString(),
          (failures).toString(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        if (state.isInitialized && !_controlFieldsInitialized) {
          _initializeControlFields(state);
        }
        return Column(
          children: [
            // Server config card
            Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.dns, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          context.l10n.controlServer,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          icon: Icon(
                            _showConfig ? Icons.expand_less : Icons.expand_more,
                          ),
                          onPressed: () =>
                              setState(() => _showConfig = !_showConfig),
                        ),
                      ],
                    ),
                    if (_showConfig) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _hostController,
                              onChanged: (_) => _persistControlFields(),
                              decoration: InputDecoration(
                                labelText: context.l10n.host,
                                hintText: context.l10n.eG,
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 1,
                            child: TextField(
                              controller: _portController,
                              onChanged: (_) => _persistControlFields(),
                              decoration: InputDecoration(
                                labelText: context.l10n.port3,
                                isDense: true,
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: TextInputType.number,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _keyController,
                        onChanged: (_) => _persistControlFields(),
                        decoration: InputDecoration(
                          labelText: context.l10n.sessionKeyOptional,
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        obscureText: true,
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: state.isLoadingNodes
                              ? null
                              : () => _fetchNodes(),
                          icon: state.isLoadingNodes
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: Text(context.l10n.fetchNodes),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Nodes list
            Expanded(
              child: RefreshIndicator(
                onRefresh: _onRefresh,
                child: _buildBody(context, state),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ProxyState state) {
    if (state.isLoadingNodes) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.nodesError != null) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(context.l10n.error((state.nodesError).toString())),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _onRefresh,
                  child: Text(context.l10n.retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (state.nodes.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.dns_outlined, size: 64, color: Colors.grey),
                const SizedBox(height: 16),
                Text(context.l10n.noNodesAvailable),
                const SizedBox(height: 8),
                Text(
                  context.l10n.pullDownToRefresh,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_selectedGroupId != null &&
        !state.groups.any((g) => g.groupId == _selectedGroupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() => _selectedGroupId = null);
        }
      });
    }

    final filteredNodes = _filterNodes(state);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildNodeToolbar(state),
        const SizedBox(height: 12),
        if (state.groups.isNotEmpty) _buildGroupSelector(state),
        if (state.groups.isNotEmpty) const SizedBox(height: 12),
        if (filteredNodes.isEmpty)
          _buildEmptyFilterState(state)
        else
          ...filteredNodes.map((node) => _buildNodeCard(context, state, node)),
      ],
    );
  }

  List<NodeInfo> _filterNodes(ProxyState state) {
    return filterNodeCatalog(
      nodes: state.nodes,
      groups: state.groups,
      selectedGroupId: _selectedGroupId,
      selectedCountry: _selectedCountry,
      query: _searchQuery,
      sortByLatency: state.sortNodesByLatency,
      countryOf: state.effectiveCountry,
    );
  }

  /// One chip per country in the catalogue, so picking a region is a click
  /// rather than a search term the user has to know.
  Widget _buildCountryChips(ProxyState state) {
    final facets = countryFacets(
      nodes: state.nodes,
      countryOf: state.effectiveCountry,
    );
    if (facets.length < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilterChip(
            label: Text(context.l10n.all((state.nodes.length).toString())),
            selected: _selectedCountry == null,
            onSelected: (_) => setState(() => _selectedCountry = null),
          ),
          for (final facet in facets)
            FilterChip(
              avatar: _buildCountryFlag(facet.code),
              label: Text('${facet.code} (${facet.count})'),
              selected: _selectedCountry == facet.code,
              onSelected: (selected) => setState(
                () => _selectedCountry = selected ? facet.code : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNodeToolbar(ProxyState state) {
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        OutlinedButton.icon(
          onPressed: _isTestingAll ? null : () => _testAllNodes(state),
          icon: _isTestingAll
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping, size: 18),
          label: Text(context.l10n.testAll),
        ),
        PopupMenuButton<bool>(
          tooltip: context.l10n.sortNodes,
          initialValue: state.sortNodesByLatency,
          onSelected: state.setSortNodesByLatency,
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: false,
              checked: !state.sortNodesByLatency,
              child: Text(context.l10n.serverOrder),
            ),
            CheckedPopupMenuItem(
              value: true,
              checked: state.sortNodesByLatency,
              child: Text(context.l10n.latency),
            ),
          ],
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort, size: 18),
                const SizedBox(width: 8),
                Text(
                  state.sortNodesByLatency
                      ? context.l10n.latency
                      : context.l10n.serverOrder,
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 18),
              ],
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSearchField(),
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerRight, child: actions),
              _buildCountryChips(state),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 8),
                actions,
              ],
            ),
            _buildCountryChips(state),
          ],
        );
      },
    );
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      onChanged: (value) => setState(() => _searchQuery = value),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: context.l10n.searchNodesRegionsAddressesOrGroups,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.clearSearch,
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _buildGroupSelector(ProxyState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.group, size: 18),
                const SizedBox(width: 8),
                Text(
                  context.l10n.groups,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                if (state.groupsError != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '(${state.groupsError})',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(context.l10n.all2),
                  selected: _selectedGroupId == null,
                  onSelected: (_) => setState(() => _selectedGroupId = null),
                ),
                ...state.groups.map(
                  (group) => ChoiceChip(
                    label: Text('${group.name} (${group.nodeIds.length})'),
                    selected: _selectedGroupId == group.groupId,
                    onSelected: (_) =>
                        setState(() => _selectedGroupId = group.groupId),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyFilterState(ProxyState state) {
    if (_searchQuery.trim().isNotEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.search_off),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.noNodesMatch((_searchQuery.trim()).toString()),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_selectedGroupId == null) {
      return const SizedBox.shrink();
    }
    if (state.groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final group = state.groups.firstWhere(
      (g) => g.groupId == _selectedGroupId,
      orElse: () => state.groups.first,
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.info_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.l10n.noNodesInGroup((group.name).toString()),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(BuildContext context, ProxyState state, NodeInfo node) {
    final isCurrent = state.isCurrentNode(node);
    final verificationNote = _buildVerificationNote(context, state, node);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header with badge
            Row(
              children: [
                if (isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      context.l10n.currentNode,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                if (isCurrent) const SizedBox(width: 8),
                _buildNodeFlag(context, state, node),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${state.effectiveCountry(node)}'
                    '${node.region.isNotEmpty ? ' - ${node.region}' : ''}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Address
            Text(
              node.addr,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),

            // Last seen
            Text(
              context.l10n.lastSeen(
                (_formatLastSeen(node.lastSeen)).toString(),
              ),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),

            // Latency (if available)
            if (node.latencyMs != null) ...[
              const SizedBox(height: 4),
              Text(
                context.l10n.latencyMs((node.latencyMs).toString()),
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],

            if (verificationNote != null) ...[
              const SizedBox(height: 4),
              verificationNote,
            ],

            const SizedBox(height: 12),

            // Action buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                // Export Config button (always available)
                ElevatedButton.icon(
                  onPressed: () => _exportConfig(context, node),
                  icon: const Icon(Icons.file_download, size: 18),
                  label: Text(context.l10n.exportLabel),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: state.isVerifyingNode(node)
                      ? null
                      : () => _verifyNode(context, node),
                  icon: state.isVerifyingNode(node)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed, size: 18),
                  label: Text(context.l10n.testLabel),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                if (!isCurrent)
                  ElevatedButton.icon(
                    onPressed:
                        _switchLoading[node.nodeId] == true || state.isTunBusy
                        ? null
                        : () => _switchNode(context, node),
                    icon: _switchLoading[node.nodeId] == true
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.swap_horiz, size: 18),
                    label: Text(context.l10n.switchLabel),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inSeconds < 60) {
      return context.l10n.sAgo((diff.inSeconds).toString());
    } else if (diff.inMinutes < 60) {
      return context.l10n.mAgo((diff.inMinutes).toString());
    } else if (diff.inHours < 24) {
      return context.l10n.hAgo((diff.inHours).toString());
    } else {
      return context.l10n.dAgo((diff.inDays).toString());
    }
  }

  /// The flag slot, which doubles as the verification indicator.
  ///
  /// A node that did not answer gets a distinct mark rather than the flag of a
  /// country its traffic never reaches — the whole point of verifying is that
  /// the catalogue's claim cannot be trusted on its own.
  Widget _buildNodeFlag(BuildContext context, ProxyState state, NodeInfo node) {
    final theme = Theme.of(context);
    if (state.isVerifyingNode(node)) {
      return const SizedBox(
        width: 28,
        height: 20,
        child: Center(
          child: SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final verification = state.verificationFor(node);
    if (verification != null && !verification.isVerified) {
      return Tooltip(
        message: verification.error ?? context.l10n.thisNodeDidNotAnswer,
        child: SizedBox(
          width: 28,
          height: 20,
          child: Icon(
            Icons.cloud_off,
            size: 18,
            color: theme.colorScheme.error,
          ),
        ),
      );
    }

    return _buildCountryFlag(state.effectiveCountry(node));
  }

  /// Extract country code from string and build flag widget
  Widget _buildCountryFlag(String country) {
    // Try to find a 2-letter country code in the string
    final match = RegExp(r'[A-Z]{2}').firstMatch(country.toUpperCase());
    if (match != null) {
      // country_flags 4.x moved sizing into the theme object.
      return CountryFlag.fromCountryCode(
        match.group(0)!,
        theme: const ImageTheme(height: 20, width: 28),
      );
    }
    // Fallback to a generic icon
    return const Icon(Icons.flag, size: 20);
  }

  /// One line describing what the last probe found, or nothing before one ran.
  Widget? _buildVerificationNote(
    BuildContext context,
    ProxyState state,
    NodeInfo node,
  ) {
    final verification = state.verificationFor(node);
    if (verification == null) return null;
    final theme = Theme.of(context);

    if (!verification.isVerified) {
      return Text(
        context.l10n.unreachable(
          (verification.error ?? context.l10n.noAnswer).toString(),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      );
    }

    final drifted = verification.disagreesWith(node.country);
    final parts = <String>[
      context.l10n.egress((verification.countryCode).toString()),
      if (verification.egressIp.isNotEmpty) verification.egressIp,
      if (verification.latencyMs != null) '${verification.latencyMs}ms',
    ];
    return Text(
      drifted
          ? context.l10n.catalogueSays(
              (parts.join(' · ')).toString(),
              (node.country).toString(),
            )
          : parts.join(' · '),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: drifted
            ? theme.colorScheme.tertiary
            : theme.colorScheme.onSurfaceVariant,
      ),
    );
  }

  Future<void> _verifyNode(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    final state = context.read<ProxyState>();
    final verification = await state.verifyNode(node);
    if (verification == null) return;
    if (verification.isVerified) {
      ToastUtils.showSuccess(
        strings.trafficLeavesFrom(
          (verification.countryCode).toString(),
          (verification.egressIp.isEmpty ? '' : ' (${verification.egressIp})')
              .toString(),
        ),
      );
    } else {
      ToastUtils.showError(
        verification.error ?? strings.couldNotReach((node.addr).toString()),
      );
    }
  }
}
