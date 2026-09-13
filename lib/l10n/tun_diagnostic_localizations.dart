import '../src/services/macos_tun_diagnostics.dart';
import 'generated/app_localizations.dart';

extension LocalizedTunIssue on TunDiagnosticIssue {
  String localizedMessage(AppLocalizations strings) => switch (area) {
    TunDiagnosticArea.route => strings.diagnosticReadRouteError(subject),
    TunDiagnosticArea.owners => strings.diagnosticReadOwnershipError,
    TunDiagnosticArea.process => strings.diagnosticReadProcessError(subject),
  };
}

extension LocalizedTunReport on TunDiagnosticReport {
  String localizedSummary(AppLocalizations strings) => [
    strings.diagnosticSummaryTitle,
    for (final route in routes)
      strings.diagnosticRouteSummary(
        route.destination,
        route.interfaceName ?? strings.unknown,
        route.gateway ?? strings.unknown,
      ),
    for (final owner in owners)
      '${owner.interfaceName} · ${owner.executablePath == null ? strings.tunUnknownProcess : owner.displayName}'
          ' · PID ${owner.pid ?? strings.unknown}'
          '${owner.executablePath == null ? "" : "\n${owner.executablePath}"}',
    for (final issue in issues) issue.localizedMessage(strings),
  ].join('\n');
}
