import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../models/proxy_config.dart';
import '../providers/proxy_provider.dart';
import '../services/build_capabilities.dart';
import '../services/tray_service.dart';
import '../utils/toast_utils.dart';
import '../widgets/android_vpn_app_dialog.dart';
import '../widgets/config_dialog.dart';
import '../widgets/tun_diagnostics_dialog.dart';
import '../widgets/tun_process_dialog.dart';

/// Whether this platform can pick processes to keep out of the tunnel.
///
/// Windows and macOS both resolve a captured session back to its owning process
/// and can relay it directly through the physical interface. Android has a
/// separate VPN app picker. iOS per-app VPN requires MDM-managed apps, and Linux
/// has no process enumeration wired up.
final bool supportsTunProcessBypass =
    !BuildCapabilities.usesPacketTunnel &&
    (Platform.isWindows || Platform.isMacOS);

/// Whether traffic capture is the platform's VPN rather than a TUN device.
bool get captureIsVpn =>
    Platform.isAndroid || BuildCapabilities.usesPacketTunnel;

/// Start or stop the proxy, with the outcome as a toast.
Future<void> toggleProxy(BuildContext context) async {
  final state = context.read<ProxyState>();
  final strings = context.l10n;
  if (state.isProxyOperationInProgress) return;
  if (state.isRunning) {
    final success = await state.stop();
    success
        ? ToastUtils.showSuccess(strings.proxyStopped)
        : ToastUtils.showError(state.lastError ?? strings.failedToStopProxy);
  } else {
    final success = await state.start();
    success
        ? ToastUtils.showSuccess(strings.proxyStarted)
        : ToastUtils.showError(state.lastError ?? strings.failedToStartProxy2);
  }
}

/// Whether the power control can act right now.
bool canToggleProxy(ProxyState state) =>
    state.config.serverHost.isNotEmpty &&
    !state.isTunBusy &&
    !state.isProxyOperationInProgress;

Future<void> showConfigDialog(
  BuildContext context, {
  ProxyConfigModel? initialConfig,
}) => showDialog<void>(
  context: context,
  builder: (_) => ConfigDialog(initialConfig: initialConfig),
);

Future<void> showTunProcessDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const TunProcessDialog(),
);

Future<void> showAndroidVpnAppDialog(BuildContext context) => showDialog<void>(
  context: context,
  useSafeArea: false,
  builder: (_) => const AndroidVpnAppDialog(),
);

/// Turn traffic capture on or off, explaining a failure in a dialog.
Future<void> toggleTun(BuildContext context, bool enabled) async {
  final state = context.read<ProxyState>();
  final strings = context.l10n;
  final result = await state.setTunEnabled(enabled);
  if (!context.mounted) return;
  if (result == null) {
    ToastUtils.showInfo(strings.restartingWithAdministratorPrivilegesForTun);
    await TrayService.instance.finishElevationHandoff(state);
    return;
  }
  if (result) {
    ToastUtils.showSuccess(
      enabled ? strings.tunModeEnabled : strings.tunModeDisabled,
    );
    return;
  }
  final error = state.lastError ?? strings.failedToChangeTunMode;
  if (Platform.isMacOS && !BuildCapabilities.usesPacketTunnel) {
    await showTunDiagnostics(context, error: error, allowRetry: enabled);
  } else {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: Text(strings.tunSetupFailed),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: SelectableText(error),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.close),
          ),
        ],
      ),
    );
  }
}

Future<void> showTunDiagnostics(
  BuildContext context, {
  String? error,
  bool allowRetry = true,
}) async {
  final state = context.read<ProxyState>();
  final retry = await showDialog<bool>(
    context: context,
    builder: (_) => TunDiagnosticsDialog(
      originalError: error,
      canRetry: allowRetry && state.isRunning && !state.isTunRunning,
    ),
  );
  if (context.mounted &&
      retry == true &&
      state.isRunning &&
      !state.isTunRunning &&
      !state.isTunBusy) {
    await toggleTun(context, true);
  }
}

Future<void> exportConfigToClipboard(BuildContext context) async {
  final state = context.read<ProxyState>();
  final strings = context.l10n;
  final encoded = base64Encode(utf8.encode(jsonEncode(state.config.toJson())));
  try {
    await Clipboard.setData(ClipboardData(text: encoded));
    ToastUtils.showSuccess(strings.configExportedToClipboard);
  } catch (error) {
    ToastUtils.showError(strings.failedToCopy(error.toString()));
  }
}

Future<void> importConfigFromClipboard(BuildContext context) async {
  final strings = context.l10n;
  try {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      ToastUtils.showWarning(strings.clipboardIsEmpty);
      return;
    }
    final config = ProxyConfigModel.fromJson(
      jsonDecode(utf8.decode(base64Decode(text))),
    );
    if (context.mounted) {
      await showConfigDialog(context, initialConfig: config);
    }
  } catch (_) {
    ToastUtils.showError(strings.invalidConfigFormat);
  }
}

/// "TUN / TCP + UDP proxy", "SOCKS5 TCP only", …: what the connection carries.
String connectionModeLabel(BuildContext context, ProxyState state) {
  final strings = context.l10n;
  if (state.isTunRunning) {
    final capture = captureIsVpn ? 'VPN' : 'TUN';
    if (BuildCapabilities.usesPacketTunnel) {
      return state.config.udpEnabled
          ? strings.tcpProxyUdpCountryProxy(capture)
          : strings.tcpProxyUdpCountryReject(capture);
    }
    if (state.config.udpEnabled) return strings.tcpUdpProxy(capture);
    return state.config.udpDirectFallback
        ? strings.tcpProxyUdpDirect(capture)
        : strings.tcpProxyUdpBlocked(capture);
  }
  return state.config.udpEnabled ? strings.socksTcpUdp : strings.socksTcpOnly;
}

/// One line on what traffic capture is doing.
String captureStatusLabel(BuildContext context, ProxyState state) {
  final strings = context.l10n;
  if (state.isTunBusy) {
    return captureIsVpn
        ? strings.configuringVpn
        : strings.configuringAdapterAndRoutes;
  }
  if (!state.isRunning) return strings.startTheLocalProxyFirst;
  if (state.isTunRunning) {
    return captureIsVpn
        ? strings.vpnTraffic(state.config.localPort.toString())
        : strings.allTraffic(state.config.localPort.toString());
  }
  if (Platform.isAndroid) return strings.androidVpnIsOff;
  return captureIsVpn
      ? strings.deviceTrafficIsNotCaptured
      : strings.systemTrafficCaptureIsOff;
}
