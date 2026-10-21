import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/proxy_launcher.dart';
import '../services/proxy_launcher_service.dart';
import '../theme/app_theme.dart';
import '../utils/toast_utils.dart';

/// Configured apps first, then installed apps that one click sets up with the
/// current proxy port and default rules. Each app is shown by its own icon,
/// so rows carry no paths or mode descriptions.
class LauncherPage extends StatefulWidget {
  const LauncherPage({super.key, required this.defaultPort, this.service});

  final int defaultPort;
  final ProxyLauncherService? service;

  @override
  State<LauncherPage> createState() => _LauncherPageState();
}

enum _RowAction { edit, reveal, remove }

class _LauncherPageState extends State<LauncherPage> {
  late final _service = widget.service ?? ProxyLauncherService.forPlatform();
  List<ProxyLauncher> _launchers = [];
  List<LauncherApplication> _detected = [];
  Map<String, Uint8List> _icons = {};
  bool _loaded = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(() async {
      // Detection only adds suggestions; it must not hide configured apps.
      final detected = _service.discoverApplications().then(
        (apps) => apps,
        onError: (Object _) => <LauncherApplication>[],
      );
      try {
        await _reload();
      } finally {
        final apps = await detected;
        if (mounted) {
          setState(() {
            _detected = apps;
            _loaded = true;
          });
        }
        unawaited(_loadIcons());
      }
    });
  }

  Future<void> _reload() async {
    final entries = await _service.list();
    if (mounted) setState(() => _launchers = entries);
  }

  Future<void> _loadIcons() async {
    try {
      final icons = await _service.icons({
        for (final launcher in _launchers) launcher.appPath,
        for (final app in _detected) app.path,
      });
      if (mounted) setState(() => _icons = icons);
    } catch (_) {
      // Rows keep the generic application icon.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
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

  String _appName(ProxyLauncher launcher) =>
      _detected.where((app) => app.hasLauncher(launcher)).firstOrNull?.name ??
      _basename(launcher.appPath);

  void _saved(ProxyLauncher launcher) {
    final strings = context.l10n;
    final name = _appName(launcher);
    ToastUtils.showSuccess(
      launcher.isNative
          ? strings.appProxyReopen(name)
          : strings.appProxyReopenLauncher(name),
    );
  }

  Future<void> _setUp(LauncherApplication app) => _run(() async {
    final saved = await _service.setUp(
      app,
      entries: _launchers,
      port: widget.defaultPort,
      suffix: context.l10n.proxyLauncherSuffix,
    );
    await _reload();
    if (mounted) _saved(saved);
  });

  Future<void> _usePort(ProxyLauncher launcher) => _run(() async {
    final saved = await _service.save(
      launcher.copyWith(port: widget.defaultPort),
    );
    await _reload();
    if (mounted) _saved(saved);
  });

  Future<void> _add() async {
    LauncherApplication? app;
    await _run(() async => app = await _service.chooseApplication());
    final chosen = app;
    if (!mounted || chosen == null) return;
    await _edit(
      ProxyLauncher(
        name: _defaultName(chosen.name, chosen.mode),
        appPath: chosen.path,
        applicationId: chosen.id,
        mode: chosen.mode,
        port: widget.defaultPort,
        bypassRules: ProxyLauncher.defaultBypassRules,
      ),
      chosen.name,
    );
  }

  Future<void> _edit(ProxyLauncher launcher, [String? appName]) async {
    // A Claude launcher from before native support moves to native settings.
    final upgrade =
        !launcher.isNative &&
        _detected.any(
          (app) =>
              app.mode == LauncherMode.claudeNative &&
              app.hasLauncher(launcher),
        );
    final saved = await showDialog<ProxyLauncher>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LauncherEditor(
        service: _service,
        currentPort: widget.defaultPort,
        appName: appName ?? _appName(launcher),
        icon: _icons[launcher.appPath],
        initial: upgrade
            ? launcher.copyWith(mode: LauncherMode.claudeNative)
            : launcher,
      ),
    );
    if (saved == null || !mounted) return;
    await _run(_reload);
    unawaited(_loadIcons());
    if (mounted) _saved(saved);
  }

  Future<void> _remove(ProxyLauncher launcher) async {
    final strings = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: _AppIcon(_icons[launcher.appPath], size: 48),
        title: Text(strings.removeAppProxyTitle(launcher.name)),
        content: Text(
          launcher.isNative
              ? strings.removeNativeProxyHint
              : strings.trashLauncherHint,
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.removeAppProxy),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await _service.trash(launcher);
      await _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pending = ProxyLauncherService.pending(_detected, _launchers);
    final empty = _loaded && _launchers.isEmpty && pending.isEmpty;
    final add = FilledButton.tonalIcon(
      onPressed: _busy ? null : _add,
      icon: const Icon(Icons.add),
      label: Text(strings.createLauncher),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      strings.appLaunchers,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!empty) add,
                ],
              ),
              if (_loaded && _launchers.isEmpty && !empty) ...[
                const SizedBox(height: 6),
                Text(
                  strings.noLaunchers,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              if (_error != null) ...[
                _ErrorBanner(
                  message: _error!,
                  onClose: () => setState(() => _error = null),
                ),
                const SizedBox(height: 12),
              ],
              if (empty) _EmptyState(action: add),
              if (_launchers.isNotEmpty)
                _Group(
                  children: [
                    for (final launcher in _launchers) _configuredRow(launcher),
                  ],
                ),
              if (pending.isNotEmpty) ...[
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    4,
                    _launchers.isEmpty ? 0 : 28,
                    4,
                    10,
                  ),
                  child: Text(
                    strings.detectedApps,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _Group(
                  children: [
                    for (final app in pending)
                      _AppRow(
                        key: ValueKey(app.path),
                        icon: _icons[app.path],
                        title: app.name,
                        trailing: FilledButton.icon(
                          onPressed: _busy ? null : () => _setUp(app),
                          icon: const Icon(Icons.add),
                          label: Text(strings.setUpApp),
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _configuredRow(ProxyLauncher launcher) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final synced = launcher.port == widget.defaultPort;
    final stale = StatusColors.of(context).slow;
    final warning = launcher.warning;
    return _AppRow(
      key: ValueKey(launcher.id),
      icon: _icons[launcher.appPath],
      title: launcher.name,
      onTap: _busy ? null : () => _edit(launcher),
      subtitle: warning != null
          ? Tooltip(
              message: warning,
              child: Text(
                strings.nativeRoutingUnavailable,
                style: muted?.copyWith(color: scheme.error),
              ),
            )
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '127.0.0.1:${launcher.port}',
                    style: synced
                        ? null
                        : TextStyle(color: stale, fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        '  ·  ${strings.directRuleCount(launcher.bypassRules.length)}',
                  ),
                ],
              ),
              style: muted,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!synced)
            IconButton(
              onPressed: _busy ? null : () => _usePort(launcher),
              tooltip: strings.useCurrentProxyPort(widget.defaultPort),
              color: stale,
              icon: const Icon(Icons.sync),
            ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : () => _run(() => _service.open(launcher)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(strings.openLauncher),
          ),
          PopupMenuButton<_RowAction>(
            enabled: !_busy,
            icon: const Icon(Icons.more_vert),
            onSelected: (action) => switch (action) {
              _RowAction.edit => _edit(launcher),
              _RowAction.reveal => _run(() => _service.reveal(launcher)),
              _RowAction.remove => _remove(launcher),
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: _RowAction.edit,
                child: ListTile(
                  leading: const Icon(Icons.tune),
                  title: Text(strings.editLauncher),
                ),
              ),
              PopupMenuItem(
                value: _RowAction.reveal,
                child: ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: Text(strings.revealLauncher),
                ),
              ),
              PopupMenuItem(
                value: _RowAction.remove,
                child: ListTile(
                  leading: Icon(Icons.delete_outline, color: scheme.error),
                  title: Text(
                    strings.removeAppProxy,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _defaultName(String app, LauncherMode mode) =>
      mode == LauncherMode.claudeNative
      ? app
      : '$app ${context.l10n.proxyLauncherSuffix}';
}

String _message(Object error) =>
    error is PlatformException ? error.message ?? error.code : error.toString();

String _basename(String path) {
  final name = path.split(RegExp(r'[/\\]')).lastWhere((part) => part != '');
  return name.replaceFirst(RegExp(r'\.(app|exe)$', caseSensitive: false), '');
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      children: [
        for (final (index, child) in children.indexed) ...[
          if (index > 0) const Divider(indent: 72),
          child,
        ],
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.action});

  final Widget action;

  @override
  Widget build(BuildContext context) {
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
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.apps,
                size: 32,
                color: scheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.noLaunchers,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            action,
          ],
        ),
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final Uint8List? icon;
  final String title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            _AppIcon(icon, size: 40),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    subtitle!,
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// The app's own icon, or a neutral tile while it loads or when the platform
/// has none.
class _AppIcon extends StatelessWidget {
  const _AppIcon(this.bytes, {required this.size});

  final Uint8List? bytes;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * 0.24),
      ),
      child: Icon(
        Icons.apps,
        size: size * 0.55,
        color: scheme.onSurfaceVariant,
      ),
    );
    final icon = bytes;
    return SizedBox.square(
      dimension: size,
      child: icon == null
          ? fallback
          : Image.memory(
              icon,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) => fallback,
            ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: SelectableText(
                message,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            IconButton(
              onPressed: onClose,
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              icon: Icon(Icons.close, color: scheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class _LauncherEditor extends StatefulWidget {
  const _LauncherEditor({
    required this.service,
    required this.initial,
    required this.appName,
    required this.currentPort,
    this.icon,
  });

  final ProxyLauncherService service;
  final ProxyLauncher initial;
  final String appName;
  final int currentPort;
  final Uint8List? icon;

  @override
  State<_LauncherEditor> createState() => _LauncherEditorState();
}

class _LauncherEditorState extends State<_LauncherEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial.name);
  late final _port = TextEditingController(text: '${widget.initial.port}');
  final _newRule = TextEditingController();
  final _ruleFocus = FocusNode();
  late final _rules = List.of(widget.initial.bypassRules);
  late String _appPath = widget.initial.appPath;
  late String _appName = widget.appName;
  late Uint8List? _icon = widget.icon;
  late LauncherMode _mode = widget.initial.mode;
  late String? _applicationId = widget.initial.applicationId;
  bool _saving = false;
  String? _ruleError;
  String? _error;

  bool get _native => _mode == LauncherMode.claudeNative;

  @override
  void initState() {
    super.initState();
    _ruleFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _port.dispose();
    _newRule.dispose();
    _ruleFocus.dispose();
    super.dispose();
  }

  String _defaultName(String app, LauncherMode mode) =>
      mode == LauncherMode.claudeNative
      ? app
      : '$app ${context.l10n.proxyLauncherSuffix}';

  Future<void> _choose() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final app = await widget.service.chooseApplication();
      if (app == null) return;
      final icons = await widget.service.icons([app.path]);
      if (!mounted) return;
      setState(() {
        // Follow the new app unless the user has renamed the launcher.
        if (_name.text == _defaultName(_appName, _mode)) {
          _name.text = _defaultName(app.name, app.mode);
        }
        _appPath = app.path;
        _appName = app.name;
        _icon = icons[app.path];
        _mode = app.mode;
        _applicationId = app.id;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Moves typed or pasted hosts into the list. False when they are invalid.
  bool _commitRules() {
    final added = ProxyLauncher.parseRules(_newRule.text);
    if (added.isEmpty) return true;
    final rules = {..._rules, ...added}.toList();
    final strings = context.l10n;
    final error = !ProxyLauncher.validRules(added)
        ? strings.invalidLauncherRules
        : !ProxyLauncher.validRules(rules)
        ? strings.tooManyLauncherRules
        : null;
    setState(() {
      _ruleError = error;
      if (error == null) {
        _rules
          ..clear()
          ..addAll(rules);
        _newRule.clear();
      }
    });
    return error == null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || !_commitRules()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.service.save(
        ProxyLauncher(
          id: widget.initial.id,
          name: _name.text.trim(),
          appPath: _appPath,
          applicationId: _applicationId,
          mode: _mode,
          port: int.parse(_port.text),
          bypassRules: _rules,
        ),
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fixedApp = widget.initial.isNative && widget.initial.id != null;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 16, 0),
        title: Row(
          children: [
            _AppIcon(_icon, size: 48),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge,
                  ),
                  Text(
                    _appPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (!fixedApp)
              TextButton(
                onPressed: _saving ? null : _choose,
                child: Text(strings.chooseApplication),
              ),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  ValueListenableBuilder(
                    valueListenable: _port,
                    builder: (context, port, _) => TextFormField(
                      controller: _port,
                      enabled: !_saving,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: strings.localPort,
                        prefixText: '127.0.0.1:',
                        suffixIcon: port.text == '${widget.currentPort}'
                            ? null
                            : Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  end: 6,
                                ),
                                child: Tooltip(
                                  message: strings.useCurrentProxyPort(
                                    widget.currentPort,
                                  ),
                                  child: TextButton.icon(
                                    onPressed: _saving
                                        ? null
                                        : () => _port.text =
                                              '${widget.currentPort}',
                                    icon: const Icon(Icons.sync, size: 18),
                                    label: Text('${widget.currentPort}'),
                                  ),
                                ),
                              ),
                      ),
                      validator: (value) {
                        final port = int.tryParse(value ?? '');
                        return port != null && port >= 1 && port <= 65535
                            ? null
                            : strings.invalidLauncherPort;
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _saving ? null : _ruleFocus.requestFocus,
                    child: InputDecorator(
                      isFocused: _ruleFocus.hasFocus,
                      decoration: InputDecoration(
                        labelText: strings.directRules,
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        errorText: _ruleError,
                        enabled: !_saving,
                        suffixIcon: IconButton(
                          onPressed: _saving
                              ? null
                              : () => setState(() {
                                  _rules
                                    ..clear()
                                    ..addAll(ProxyLauncher.defaultBypassRules);
                                  _ruleError = null;
                                }),
                          tooltip: strings.resetLauncherRules,
                          icon: const Icon(Icons.restart_alt),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            for (final rule in _rules) _ruleChip(rule),
                            SizedBox(
                              width: 150,
                              child: TextField(
                                controller: _newRule,
                                focusNode: _ruleFocus,
                                enabled: !_saving,
                                style: theme.textTheme.bodyMedium,
                                decoration: InputDecoration.collapsed(
                                  hintText: strings.addDirectRule,
                                ),
                                onChanged: (_) {
                                  if (_ruleError != null) {
                                    setState(() => _ruleError = null);
                                  }
                                },
                                onSubmitted: (_) {
                                  _commitRules();
                                  _ruleFocus.requestFocus();
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!_native) ...[
                    const SizedBox(height: 16),
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
                    SegmentedButton<LauncherMode>(
                      segments: [
                        ButtonSegment(
                          value: LauncherMode.chromium,
                          icon: const Icon(Icons.public),
                          label: Text(strings.chromiumMode),
                        ),
                        ButtonSegment(
                          value: LauncherMode.environment,
                          icon: const Icon(Icons.terminal),
                          label: Text(strings.environmentMode),
                        ),
                      ],
                      selected: {_mode},
                      showSelectedIcon: false,
                      onSelectionChanged: _saving
                          ? null
                          : (value) => setState(() => _mode = value.single),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.error_outline, color: scheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(
                              _error!,
                              style: TextStyle(color: scheme.error),
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
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(strings.save),
          ),
        ],
      ),
    );
  }

  Widget _ruleChip(String rule) {
    // Environment-only launchers cannot express arbitrary patterns.
    final skipped =
        _mode == LauncherMode.environment &&
        !ProxyLauncher.appliesToEnvironment(rule);
    final chip = InputChip(
      label: Text(
        rule,
        style: skipped
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      onDeleted: _saving ? null : () => setState(() => _rules.remove(rule)),
    );
    return skipped
        ? Tooltip(
            message: context.l10n.ruleSkippedByEnvironment,
            child: Opacity(opacity: 0.55, child: chip),
          )
        : chip;
  }
}
