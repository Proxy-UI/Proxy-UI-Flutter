import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/proxy_launcher.dart';
import '../services/proxy_launcher_service.dart';

class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key, required this.defaultPort, this.service});

  final int defaultPort;
  final ProxyLauncherService? service;

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

class _LauncherPageState extends State<LauncherPage> {
  late final _service = widget.service ?? ProxyLauncherService.forPlatform();
  List<ProxyLauncher> _launchers = [];
  bool _busy = true;
  String? _error;
  String? _generationSummary;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => _operation(() async {
    final entries = await _service.list();
    if (mounted) setState(() => _launchers = entries);
  });

  Future<void> _operation(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([ProxyLauncher? launcher]) async {
    LauncherApplication? app;
    if (launcher == null) {
      await _operation(() async => app = await _service.chooseApplication());
      if (!mounted || app == null) return;
    }
    if (launcher != null &&
        !launcher.isNative &&
        launcher.applicationId == 'com.anthropic.claudefordesktop') {
      await _operation(() async {
        final apps = await _service.discoverApplications();
        final detected = apps
            .where((app) => app.hasLauncher(launcher!))
            .firstOrNull;
        if (detected?.mode == LauncherMode.claudeNative) {
          launcher = launcher!.withMode(LauncherMode.claudeNative);
        }
      });
    }
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LauncherEditor(
        service: _service,
        currentPort: widget.defaultPort,
        initial:
            launcher ??
            ProxyLauncher(
              name: '${app!.name} ${context.l10n.proxyLauncherSuffix}',
              appPath: app!.path,
              applicationId: app!.id,
              mode: app!.mode,
              port: widget.defaultPort,
              bypassRules: ProxyLauncher.defaultBypassRules,
            ),
      ),
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _generateKnown() => _operation(() async {
    final strings = context.l10n;
    setState(() => _generationSummary = null);
    final result = await _service.generateKnownApplications(
      port: widget.defaultPort,
      suffix: strings.proxyLauncherSuffix,
    );
    final entries = await _service.list();
    if (!mounted) return;
    setState(() {
      _launchers = entries;
      _generationSummary =
          result.created.isEmpty &&
              result.existing.isEmpty &&
              result.failures.isEmpty
          ? strings.noKnownLauncherApps
          : [
              if (result.created.isNotEmpty)
                '${strings.launchersCreated}: ${result.created.join(', ')}',
              if (result.existing.isNotEmpty)
                '${strings.launchersKept}: ${result.existing.join(', ')}',
              for (final entry in result.failures.entries)
                '${entry.key}: ${_message(entry.value)}',
            ].join('\n');
    });
  });

  Future<void> _trash(ProxyLauncher launcher) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          launcher.isNative
              ? context.l10n.removeNativeProxy
              : context.l10n.trashLauncher,
        ),
        content: Text(
          launcher.isNative
              ? context.l10n.removeNativeProxyHint
              : context.l10n.trashLauncherHint,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              launcher.isNative
                  ? context.l10n.removeNativeProxy
                  : context.l10n.trashLauncher,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _operation(() async {
      await _service.trash(launcher);
      final entries = await _service.list();
      if (mounted) setState(() => _launchers = entries);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  strings.appLaunchers,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(strings.launchersHint),
                const SizedBox(height: 8),
                Text(
                  '${strings.currentProxyPort}: 127.0.0.1:${widget.defaultPort}',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _generateKnown,
                      icon: const Icon(Icons.auto_awesome),
                      label: Text(strings.generateKnownLaunchers),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _edit(),
                      icon: const Icon(Icons.add),
                      label: Text(strings.createLauncher),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _load,
                      icon: const Icon(Icons.refresh),
                      label: Text(strings.refreshLaunchers),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(strings.knownLaunchersHint),
                if (_generationSummary != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(_generationSummary!),
                  ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(
                      '${strings.launcherOperationFailed}\n$_error',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (!_busy && _error == null && _launchers.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(strings.noLaunchers),
                    ),
                  ),
                for (final launcher in _launchers)
                  Card(
                    key: ValueKey(launcher.id),
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            launcher.name,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(launcher.appPath),
                          if (launcher.warning != null)
                            Text(
                              '${strings.nativeRoutingUnavailable}\n${launcher.warning}',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          Text('HTTP · 127.0.0.1:${launcher.port}'),
                          Text(
                            launcher.isNative
                                ? strings.claudeNativeMode
                                : launcher.mode == LauncherMode.chromium
                                ? strings.chromiumMode
                                : strings.environmentMode,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            strings.directRules,
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Chip(label: Text(strings.loopbackAlwaysDirect)),
                              for (final rule in launcher.bypassRules)
                                Chip(label: Text(rule)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _operation(
                                        () => _service.open(launcher),
                                      ),
                                icon: const Icon(Icons.play_arrow),
                                label: Text(strings.openLauncher),
                              ),
                              TextButton.icon(
                                onPressed: _busy ? null : () => _edit(launcher),
                                icon: const Icon(Icons.tune),
                                label: Text(strings.editLauncher),
                              ),
                              TextButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _operation(
                                        () => _service.reveal(launcher),
                                      ),
                                icon: const Icon(Icons.folder_open),
                                label: Text(strings.revealLauncher),
                              ),
                              IconButton(
                                onPressed: _busy
                                    ? null
                                    : () => _trash(launcher),
                                icon: const Icon(Icons.delete_outline),
                                tooltip: launcher.isNative
                                    ? strings.removeNativeProxy
                                    : strings.trashLauncher,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  strings.launcherPlacementHint,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

String _message(Object error) =>
    error is PlatformException ? error.message ?? error.code : error.toString();

class _LauncherEditor extends StatefulWidget {
  const _LauncherEditor({
    required this.service,
    required this.initial,
    required this.currentPort,
  });
  final int currentPort;
  final ProxyLauncherService service;
  final ProxyLauncher initial;

  @override
  State<_LauncherEditor> createState() => _LauncherEditorState();
}

class _LauncherEditorState extends State<_LauncherEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial.name);
  late final _port = TextEditingController(text: '${widget.initial.port}');
  late final _rules = TextEditingController(
    text: widget.initial.bypassRules.join('\n'),
  );
  late String _appPath = widget.initial.appPath;
  late LauncherMode _mode = widget.initial.mode;
  late String? _applicationId = widget.initial.applicationId;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    _rules.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    setState(() => _saving = true);
    try {
      final app = await widget.service.chooseApplication();
      if (mounted && app != null) {
        setState(() {
          _appPath = app.path;
          _mode = app.mode;
          _applicationId = app.id;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.save(
        ProxyLauncher(
          id: widget.initial.id,
          name: _name.text.trim(),
          appPath: _appPath,
          applicationId: _applicationId,
          mode: _mode,
          port: int.parse(_port.text),
          bypassRules: ProxyLauncher.parseRules(_rules.text),
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Text(
          widget.initial.id == null
              ? strings.createLauncher
              : strings.editLauncher,
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _name,
                    enabled: !_saving,
                    decoration: InputDecoration(
                      labelText: strings.launcherName,
                    ),
                    validator: (value) => ProxyLauncher.validName(value ?? '')
                        ? null
                        : strings.invalidLauncherName,
                  ),
                  const SizedBox(height: 16),
                  Text(strings.targetApplication),
                  SelectableText(_appPath),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed:
                          _saving ||
                              (widget.initial.isNative &&
                                  widget.initial.id != null)
                          ? null
                          : _choose,
                      icon: const Icon(Icons.folder_open),
                      label: Text(strings.chooseApplication),
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<LauncherMode>(
                    key: ValueKey(_mode),
                    initialValue: _mode,
                    decoration: InputDecoration(labelText: strings.launchMode),
                    items: [
                      if (_mode == LauncherMode.claudeNative)
                        DropdownMenuItem(
                          value: LauncherMode.claudeNative,
                          child: Text(strings.claudeNativeMode),
                        ),
                      if (_mode != LauncherMode.claudeNative) ...[
                        DropdownMenuItem(
                          value: LauncherMode.chromium,
                          child: Text(strings.chromiumMode),
                        ),
                        DropdownMenuItem(
                          value: LauncherMode.environment,
                          child: Text(strings.environmentMode),
                        ),
                      ],
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() => _mode = value!),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _mode == LauncherMode.claudeNative
                        ? strings.claudeNativeHint
                        : strings.launchModeHint,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _port,
                    enabled: !_saving,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: strings.localPort,
                      prefixText: '127.0.0.1:',
                    ),
                    validator: (value) {
                      final port = int.tryParse(value ?? '');
                      return port != null && port >= 1 && port <= 65535
                          ? null
                          : strings.invalidLauncherPort;
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _saving
                          ? null
                          : () => _port.text = '${widget.currentPort}',
                      child: Text(
                        '${strings.useCurrentProxyPort} (${widget.currentPort})',
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _rules,
                    enabled: !_saving,
                    minLines: 4,
                    maxLines: 8,
                    decoration: InputDecoration(labelText: strings.directRules),
                    validator: (value) =>
                        ProxyLauncher.validRules(
                          ProxyLauncher.parseRules(value ?? ''),
                        )
                        ? null
                        : strings.invalidLauncherRules,
                  ),
                  const SizedBox(height: 8),
                  Text(strings.directRulesHint),
                  const SizedBox(height: 8),
                  Text(
                    _mode == LauncherMode.claudeNative
                        ? strings.nativeRulesHint
                        : strings.environmentRulesHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _saving
                          ? null
                          : () => _rules.text = ProxyLauncher.defaultBypassRules
                                .join('\n'),
                      child: Text(strings.resetLauncherRules),
                    ),
                  ),
                  Text(
                    _mode == LauncherMode.claudeNative
                        ? strings.nativeRestartHint
                        : strings.launcherRestartHint,
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(
                        '${strings.launcherOperationFailed}\n$_error',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (_saving) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(
              _mode == LauncherMode.claudeNative
                  ? strings.saveNativeProxy
                  : strings.saveLauncher,
            ),
          ),
        ],
      ),
    );
  }
}
