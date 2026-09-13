import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/l10n/tun_diagnostic_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/macos_tun_diagnostics.dart';

class TunDiagnosticsDialog extends StatefulWidget {
  final String? originalError;
  final bool canRetry;
  final Future<TunDiagnosticReport> Function()? loadReport;

  const TunDiagnosticsDialog({
    super.key,
    this.originalError,
    this.canRetry = false,
    this.loadReport,
  });

  @override
  State<TunDiagnosticsDialog> createState() => _TunDiagnosticsDialogState();
}

class _TunDiagnosticsDialogState extends State<TunDiagnosticsDialog> {
  TunDiagnosticReport? _report;
  bool _loading = true;
  bool _loadFailed = false;

  String _ownerName(TunInterfaceOwner owner) => owner.executablePath == null
      ? context.l10n.tunUnknownProcess
      : owner.displayName;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      // Never offer a command from the previous process snapshot.
      _report = null;
      _loadFailed = false;
    });
    try {
      final report =
          await (widget.loadReport ?? MacosTunDiagnostics().collect)();
      if (mounted) setState(() => _report = report);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    final color = Theme.of(context).colorScheme;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 740),
      scrollable: true,
      icon: const Icon(Icons.network_check),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.originalError == null
                ? context.l10n.tunTunNetworkDiagnostics
                : context.l10n.tunTunCouldNotStart,
          ),
          const SizedBox(height: 12),
          const LanguageMenuButton(),
        ],
      ),
      content: SizedBox(
        width: 640,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.tunIdentifyTheConnectionHandlingTrafficThenFollow,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              Text(context.l10n.tunCheckingRoutesAndTunOwnership),
            ],
            if (_loadFailed)
              Text(context.l10n.tunAutomaticChecksAreUnavailableRecheckOrCopy),
            if (report != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: color.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.routesClear
                          ? context.l10n.tunNoConflictingTunRoutesFound
                          : report.onlyCurrentApp
                          ? context.l10n.tunProxyUiIsHandlingTrafficThroughIts
                          : report.owners.isEmpty
                          ? context.l10n.tunRouteStatusCouldNotBeConfirmed
                          : context.l10n.tunATunIsCurrentlyHandlingTraffic,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    for (final route in report.routes)
                      Text(
                        '${route.destination} → ${route.interfaceName ?? context.l10n.tunUnavailable}',
                      ),
                    for (final owner in report.owners) ...[
                      const Divider(height: 24),
                      Text(
                        '${_ownerName(owner)} · ${owner.interfaceName}'
                        '${owner.pid == null ? "" : " · PID ${owner.pid}"}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (owner.executablePath != null)
                        SelectableText(
                          owner.executablePath!,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (owner.pid == null || owner.executablePath == null)
                        Text(
                          context
                              .l10n
                              .tunTheSystemDidNotProvideCompleteOwnership,
                        ),
                    ],
                    for (final issue in report.issues) ...[
                      const SizedBox(height: 8),
                      Text(issue.localizedMessage(context.l10n)),
                    ],
                  ],
                ),
              ),
              if (report.routesClear)
                Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    context.l10n.tunNeitherCheckedRouteUsesAUtunInterface,
                  ),
                ),
              if (report.onlyCurrentApp)
                Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(context.l10n.tunThisTunnelBelongsToProxyUiIf),
                ),
              if (report.owners.any((owner) => !owner.isCurrentApp)) ...[
                _step(
                  1,
                  context.l10n.tunDisconnectInTheVpnAppFirst,
                  report.owners.any((owner) => owner.isSmartVpn)
                      ? context.l10n.tunInIoaTurnOffConnectToCompany
                      : context.l10n.tunOpenTheVpnAppAssociatedWithThe,
                ),
                for (final owner in report.owners)
                  if (owner.temporaryStopCommand != null) ...[
                    _step(
                      2,
                      context.l10n.tunIfNeededTemporarilyStop(
                        (_ownerName(owner)).toString(),
                      ),
                      context.l10n.tunThisMatchesTheIdentifiedVpnProgramBy,
                    ),
                    CopyableTunCommand(
                      label: context.l10n.tunTemporaryDisconnectCommand,
                      command: owner.temporaryStopCommand!,
                    ),
                  ],
                _step(
                  report.owners.any(
                        (owner) => owner.temporaryStopCommand != null,
                      )
                      ? 3
                      : 2,
                  context.l10n.tunRecheckThenRetryTun,
                  context
                      .l10n
                      .tunClickRecheckAfterDisconnectingRetryBecomesAvailable,
                ),
                CopyableTunCommand(
                  label: context.l10n.tunInspectCurrentRoutes,
                  command: TunDiagnosticReport.verifyCommand,
                ),
                if (report.owners.any(
                  (owner) => owner.reopenCommand != null,
                )) ...[
                  _step(
                    report.owners.any(
                          (owner) => owner.temporaryStopCommand != null,
                        )
                        ? 4
                        : 3,
                    context.l10n.tunRestoreTheOriginalConnectionAfterTesting,
                    context.l10n.tunTurnOffTunInProxyUiReopen,
                  ),
                  for (final app in {
                    for (final owner in report.owners)
                      if (owner.reopenCommand != null) owner.reopenCommand!,
                  })
                    CopyableTunCommand(
                      label: context.l10n.tunReopenTheVpnApp,
                      command: app,
                    ),
                ],
              ],
              if (report.routes.any((route) => route.interfaceName == null))
                CopyableTunCommand(
                  label: context.l10n.tunInspectCurrentRoutes,
                  command: TunDiagnosticReport.verifyCommand,
                ),
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.tunDiagnosticSummary),
                children: [
                  CopyableTunCommand(
                    label: context.l10n.tunCopyDiagnosticSummary,
                    command: report.localizedSummary(context.l10n),
                  ),
                ],
              ),
            ],
            if (_loadFailed)
              CopyableTunCommand(
                label: context.l10n.tunInspectCurrentRoutes,
                command: TunDiagnosticReport.verifyCommand,
              ),
            if (widget.originalError != null) ...[
              const SizedBox(height: 12),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.tunOriginalErrorDetails),
                children: [
                  CopyableTunCommand(
                    label: context.l10n.tunCopyOriginalError,
                    command: widget.originalError!,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.close),
        ),
        OutlinedButton.icon(
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh),
          label: Text(context.l10n.tunRecheck),
        ),
        if (widget.canRetry)
          FilledButton(
            onPressed: !_loading && report?.routesClear == true
                ? () => Navigator.pop(context, true)
                : null,
            child: Text(context.l10n.tunRetryTun),
          ),
      ],
    );
  }

  Widget _step(int number, String title, String description) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 13,
          child: Text('$number', style: const TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(description),
            ],
          ),
        ),
      ],
    ),
  );
}

class CopyableTunCommand extends StatefulWidget {
  final String label;
  final String command;

  const CopyableTunCommand({
    super.key,
    required this.label,
    required this.command,
  });

  @override
  State<CopyableTunCommand> createState() => _CopyableTunCommandState();
}

class _CopyableTunCommandState extends State<CopyableTunCommand> {
  bool _copied = false;
  bool _failed = false;

  @override
  void didUpdateWidget(covariant CopyableTunCommand oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.command != widget.command) {
      _copied = false;
      _failed = false;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(top: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            TextButton.icon(
              onPressed: () async {
                try {
                  await Clipboard.setData(ClipboardData(text: widget.command));
                  if (mounted) {
                    setState(() {
                      _copied = true;
                      _failed = false;
                    });
                  }
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      _copied = false;
                      _failed = true;
                    });
                  }
                }
              },
              icon: Icon(_copied ? Icons.check : Icons.copy, size: 16),
              label: Text(_copied ? context.l10n.copied : context.l10n.copy),
            ),
          ],
        ),
        SelectableText(
          widget.command,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        if (_failed) Text(context.l10n.copyFailedSelectText),
      ],
    ),
  );
}
