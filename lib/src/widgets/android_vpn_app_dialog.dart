import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/proxy_config.dart';
import '../providers/proxy_provider.dart';
import '../services/android_vpn_service.dart';
import '../utils/toast_utils.dart';

class AndroidVpnAppDialog extends StatefulWidget {
  const AndroidVpnAppDialog({super.key});

  @override
  State<AndroidVpnAppDialog> createState() => _AndroidVpnAppDialogState();
}

class _AndroidVpnAppDialogState extends State<AndroidVpnAppDialog> {
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = {};
  List<AndroidVpnApplication> _applications = const [];
  late AndroidVpnRoutingMode _mode;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final config = context.read<ProxyState>().config;
    _mode = config.androidVpnRoutingMode;
    _selected.addAll(config.androidVpnPackages);
    _loadApplications();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadApplications({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final applications = await context
          .read<ProxyState>()
          .listAndroidVpnApplications(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() => _applications = applications);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_mode == AndroidVpnRoutingMode.include && _selected.isEmpty) {
      ToastUtils.showWarning('Select at least one application');
      return;
    }
    setState(() => _saving = true);
    final packages = _selected.toList()..sort();
    final success = await context.read<ProxyState>().updateAndroidVpnPolicy(
      _mode,
      packages,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (success) {
      Navigator.of(context).pop();
      ToastUtils.showSuccess('VPN application policy applied');
    } else {
      ToastUtils.showError(
        context.read<ProxyState>().lastError ??
            'Failed to update VPN application policy',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    if (compact) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              tooltip: 'Close',
              icon: const Icon(Icons.close),
            ),
            title: const Text('VPN applications'),
            actions: [
              IconButton(
                onPressed: _loading
                    ? null
                    : () => _loadApplications(forceRefresh: true),
                tooltip: 'Refresh applications',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: _buildContent(compact: true),
          bottomNavigationBar: Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: _buildActions(),
              ),
            ),
          ),
        ),
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.apps_outlined),
          const SizedBox(width: 12),
          const Expanded(child: Text('VPN applications')),
          IconButton(
            onPressed: _loading
                ? null
                : () => _loadApplications(forceRefresh: true),
            tooltip: 'Refresh applications',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      content: SizedBox(
        width: 620,
        height: (MediaQuery.sizeOf(context).height * .68)
            .clamp(420.0, 640.0)
            .toDouble(),
        child: _buildContent(compact: false),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildContent({required bool compact}) {
    final query = _searchController.text.trim().toLowerCase();
    final applications = _applications
        .where((application) {
          return query.isEmpty ||
              application.label.toLowerCase().contains(query) ||
              application.packageName.toLowerCase().contains(query);
        })
        .toList(growable: false);
    final selectable = _mode != AndroidVpnRoutingMode.all;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 16 : 0, 12, compact ? 16 : 0, 0),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<AndroidVpnRoutingMode>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: compact ? VisualDensity.compact : null,
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: compact ? 8 : 16),
                ),
              ),
              segments: [
                ButtonSegment(
                  value: AndroidVpnRoutingMode.all,
                  icon: compact ? null : const Icon(Icons.public),
                  label: const Text('All'),
                  tooltip: 'All other applications use VPN',
                ),
                ButtonSegment(
                  value: AndroidVpnRoutingMode.exclude,
                  icon: compact
                      ? null
                      : const Icon(Icons.remove_circle_outline),
                  label: const Text('Bypass'),
                  tooltip: 'Selected applications bypass VPN',
                ),
                ButtonSegment(
                  value: AndroidVpnRoutingMode.include,
                  icon: compact ? null : const Icon(Icons.filter_alt_outlined),
                  label: const Text('Only'),
                  tooltip: 'Only selected applications use VPN',
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _saving
                  ? null
                  : (selection) => setState(() => _mode = selection.single),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            enabled: selectable,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search apps',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.close),
                    ),
              filled: true,
              fillColor: colors.surfaceContainerHighest.withValues(alpha: .55),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                _loading
                    ? 'Loading applications...'
                    : '${applications.length} apps',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (selectable)
                Text(
                  '${_selected.length} selected',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          Expanded(
            child: !selectable
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 48,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'All other applications use VPN',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline, size: 40),
                        const SizedBox(height: 8),
                        Text(
                          _loadError!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  )
                : applications.isEmpty
                ? Center(
                    child: Text(
                      query.isEmpty
                          ? 'No applications found'
                          : 'No matching applications',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: applications.length,
                    itemBuilder: (context, index) =>
                        _buildApplicationRow(applications[index]),
                  ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    return [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      const SizedBox(width: 8),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: _saving
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.check),
        label: const Text('Apply'),
      ),
    ];
  }

  Widget _buildApplicationRow(AndroidVpnApplication application) {
    final selected = _selected.contains(application.packageName);
    return Material(
      color: selected
          ? Theme.of(
              context,
            ).colorScheme.secondaryContainer.withValues(alpha: .38)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _setSelected(application.packageName, !selected),
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (value) =>
                    _setSelected(application.packageName, value ?? false),
              ),
              const SizedBox(width: 4),
              SizedBox.square(
                dimension: 40,
                child: _AndroidVpnApplicationIcon(application: application),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      application.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      application.packageName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (application.isSystem)
                const Tooltip(
                  message: 'System application',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.android, size: 20),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _setSelected(String packageName, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(packageName);
      } else {
        _selected.remove(packageName);
      }
    });
  }
}

class _AndroidVpnApplicationIcon extends StatefulWidget {
  const _AndroidVpnApplicationIcon({required this.application});

  final AndroidVpnApplication application;

  @override
  State<_AndroidVpnApplicationIcon> createState() =>
      _AndroidVpnApplicationIconState();
}

class _AndroidVpnApplicationIconState
    extends State<_AndroidVpnApplicationIcon> {
  Uint8List? _icon;

  @override
  void initState() {
    super.initState();
    _icon = widget.application.iconPng;
    if (_icon == null) _loadIcon();
  }

  @override
  void didUpdateWidget(covariant _AndroidVpnApplicationIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.application.packageName != widget.application.packageName) {
      _icon = widget.application.iconPng;
      if (_icon == null) _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    final application = widget.application;
    final icon = await AndroidVpnService.instance.loadApplicationIcon(
      application.packageName,
    );
    if (!mounted || application.packageName != widget.application.packageName) {
      return;
    }
    setState(() => _icon = icon);
  }

  @override
  Widget build(BuildContext context) {
    final icon = _icon;
    return icon == null
        ? const Icon(Icons.apps_outlined)
        : Image.memory(icon, fit: BoxFit.contain, gaplessPlayback: true);
  }
}
