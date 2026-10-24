import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/country_atlas.dart';
import '../../models/node_model.dart';
import '../../models/upstream_endpoint.dart';
import '../../providers/proxy_provider.dart';
import '../../utils/toast_utils.dart';
import 'galaxy/galaxy_model.dart';

/// The galaxy's view of every node in the catalogue, each over the carrier
/// the node map uses for it.
List<GalaxyNode> galaxyNodesOf(ProxyState state) => [
  for (final node in state.nodes) _galaxyNodeOf(state, node),
];

GalaxyNode _galaxyNodeOf(ProxyState state, NodeInfo node) {
  final carrier = state.carrierFor(node);
  return GalaxyNode(
    node: node,
    country: normalizeCountryCode(state.effectiveCountry(node)),
    health: state.healthOf(node, carrier),
    current: state.isCurrentNode(node),
    latencyMs: state.latencyOf(node, carrier),
    quic: state.quicSupportOf(node).isAvailable,
    carrier: carrier,
  );
}

/// Ask the catalogue which nodes serve QUIC once a page shows them, rather
/// than on every launch. [ProxyState.lookUpQuicSupport] asks once per load.
void askQuicSupportAfterFrame(ProxyState state) {
  if (state.hasAskedQuicSupport || state.nodes.isEmpty) return;
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => state.lookUpQuicSupport(),
  );
}

/// What a user can do to a node, with the feedback each action gives, shared
/// by the galaxy, the list and the dashboard so they never disagree.
///
/// Tests and connections go over [ProxyState.carrierFor] each node: the
/// TCP/QUIC choice where a node serves both.
class NodeActions extends ChangeNotifier {
  NodeActions(this.state);

  final ProxyState state;
  final Set<String> _switching = {};
  final Map<String, String> _switchErrors = {};
  bool _testingMany = false;

  /// Whether any of [nodes] serves both carriers, so that choosing one
  /// means anything.
  bool offersCarrierChoice(Iterable<NodeInfo> nodes) =>
      nodes.any(state.servesBothCarriers);

  bool isSwitching(NodeInfo node) => _switching.contains(node.storageKey);

  /// Why the last [connect] to [node] failed, in the runtime's own words,
  /// until it is tried again or another switch succeeds.
  String? switchError(NodeInfo node) => _switchErrors[node.storageKey];

  /// Whether [connect] restarts TUN capture to reach [node]'s host.
  bool restartsTun(NodeInfo node) =>
      state.switchImpactOf(node) == SwitchImpact.restartsTun;

  bool get isSwitchingAny => _switching.isNotEmpty;

  bool get testingMany => _testingMany;

  /// The share of a [testMany] run that has answered.
  ///
  /// Determinate on purpose: an indeterminate spinner animates every frame,
  /// and any animation makes the engine raster the whole window again — the
  /// galaxy included — for as long as the slowest node takes to time out.
  double get testProgress => _testProgress;
  double _testProgress = 0;

  /// Whether traffic already goes through [node] over the carrier [connect]
  /// would use.
  bool inUse(NodeInfo node) => state.isRunning && state.isInUse(node);

  /// Whether [connect] can run for [node] right now. Connecting to the
  /// current node over its other carrier is a switch like any other.
  bool canConnect(NodeInfo node) =>
      !inUse(node) &&
      !state.isTunBusy &&
      !state.isProxyOperationInProgress &&
      _switching.isEmpty;

  Future<void> connect(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    if (!_switching.add(node.storageKey)) return;
    _switchErrors.remove(node.storageKey);
    notifyListeners();
    void fail(String message) {
      _switchErrors[node.storageKey] = message;
      ToastUtils.showError(message);
    }

    try {
      final success = await state.switchToNode(node);
      if (success) {
        // Another node's failure is history once a switch went through.
        _switchErrors.clear();
        ToastUtils.showSuccess(
          strings.switchedTo(_label(node, strings, language)),
        );
      } else {
        fail(state.lastError ?? strings.failedToSwitchNode);
      }
    } catch (error) {
      fail(strings.failedToSwitch(error.toString()));
    } finally {
      _switching.remove(node.storageKey);
      notifyListeners();
    }
  }

  Future<void> test(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    final verification = await state.verifyNode(node);
    if (verification == null) return;
    if (verification.isVerified) {
      ToastUtils.showSuccess(
        strings.trafficLeavesFrom(
          verification.countryCode,
          verification.egressIp.isEmpty ? '' : ' (${verification.egressIp})',
        ),
      );
    } else {
      ToastUtils.showError(
        verification.error ?? strings.couldNotReach(node.addr),
      );
    }
  }

  /// Test [nodes] together and report how many answered, and how many of
  /// them over QUIC.
  Future<void> testMany(BuildContext context, List<NodeInfo> nodes) async {
    if (_testingMany || nodes.isEmpty) return;
    final strings = context.l10n;
    _testingMany = true;
    _testProgress = 0;
    notifyListeners();
    final List<NodeVerification?> results;
    try {
      results = await state.verifyNodes(
        nodes,
        onProgress: (answered, total) {
          _testProgress = answered / total;
          notifyListeners();
        },
      );
    } finally {
      _testingMany = false;
      notifyListeners();
    }
    final failures = results
        .where((verification) => verification?.isVerified != true)
        .length;
    final overQuic = results
        .where(
          (verification) => verification?.carrier == UpstreamTransport.quic,
        )
        .length;
    final count = nodes.length.toString();
    final summary = [
      if (failures == 0)
        strings.testedNodes(count)
      else
        strings.testedReachableFailed(
          count,
          (nodes.length - failures).toString(),
          failures.toString(),
        ),
      if (overQuic > 0) strings.overQuicCount(overQuic.toString()),
    ].join(' · ');
    failures == 0
        ? ToastUtils.showSuccess(summary)
        : ToastUtils.showError(summary);
  }

  Future<void> copyAddress(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    try {
      await Clipboard.setData(ClipboardData(text: node.addr));
      ToastUtils.showSuccess(strings.addressCopied);
    } catch (error) {
      ToastUtils.showError(strings.failedToCopy(error.toString()));
    }
  }

  Future<void> export(BuildContext context, NodeInfo node) async {
    final strings = context.l10n;
    try {
      await state.exportNodeConfig(node);
      ToastUtils.showSuccess(strings.configExportedToClipboard);
    } catch (error) {
      ToastUtils.showError(strings.failedToExport(error.toString()));
    }
  }

  String _label(NodeInfo node, AppLocalizations strings, String language) {
    final code = normalizeCountryCode(state.effectiveCountry(node));
    final place = code.isEmpty
        ? strings.galaxyUnlocated
        : countryName(code, language);
    final endpoint = state.endpointOf(node, state.carrierFor(node));
    return '$place · ${endpoint?.label ?? node.addr}';
  }
}
