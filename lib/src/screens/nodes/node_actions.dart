import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/country_atlas.dart';
import '../../models/node_health.dart';
import '../../models/node_model.dart';
import '../../models/upstream_endpoint.dart';
import '../../providers/proxy_provider.dart';
import '../../utils/toast_utils.dart';
import 'galaxy/galaxy_model.dart';

/// The galaxy's view of every node in the catalogue.
List<GalaxyNode> galaxyNodesOf(ProxyState state) => [
  for (final node in state.nodes)
    GalaxyNode(
      node: node,
      country: normalizeCountryCode(state.effectiveCountry(node)),
      health: nodeHealthOf(
        testing: state.isVerifyingNode(node),
        verification: state.verificationFor(node),
        latencyMs: node.latencyMs,
      ),
      current: state.isCurrentNode(node),
      latencyMs: state.verificationFor(node)?.latencyMs ?? node.latencyMs,
      quic: state.quicSupportOf(node).isAvailable,
      testedOverQuic: state.testedCarrierOf(node) == UpstreamTransport.quic,
    ),
];

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
class NodeActions extends ChangeNotifier {
  NodeActions(this.state);

  final ProxyState state;
  final Set<String> _switching = {};
  final Map<String, String> _switchErrors = {};
  final Set<String> _withoutQuic = {};
  bool _testingMany = false;
  UpstreamTransport _testCarrier = UpstreamTransport.tcp;

  /// What tests run over where a node offers both, shared by every test
  /// button so one choice holds for the session. TCP until changed.
  UpstreamTransport get testCarrier => _testCarrier;
  set testCarrier(UpstreamTransport carrier) {
    if (carrier == _testCarrier) return;
    _testCarrier = carrier;
    if (carrier == UpstreamTransport.tcp) _withoutQuic.clear();
    notifyListeners();
  }

  /// Whether any of [nodes] can be tested over either carrier: a TCP address
  /// on a node that also reported a QUIC endpoint. Elsewhere the choice
  /// means nothing, so it is not offered.
  bool offersQuicTest(Iterable<NodeInfo> nodes) => nodes.any(
    (node) =>
        node.endpoint?.isQuic == false && state.quicSupportOf(node).isAvailable,
  );

  /// The carrier a test of [nodes] runs over right now.
  UpstreamTransport carrierFor(Iterable<NodeInfo> nodes) =>
      offersQuicTest(nodes) ? _testCarrier : UpstreamTransport.tcp;

  /// Whether the last QUIC run skipped [node] for having no QUIC endpoint.
  bool skippedWithoutQuic(NodeInfo node) =>
      _withoutQuic.contains(node.storageKey);

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

  /// Whether [connect] can run for [node] right now.
  bool canConnect(NodeInfo node) =>
      !(state.isCurrentNode(node) && state.isRunning) &&
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
    final verification = await state.verifyNode(
      node,
      carrier: carrierFor([node]),
    );
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

  /// Test [nodes] together and report how many answered.
  ///
  /// Over QUIC, nodes without a QUIC endpoint are left out and named as such
  /// rather than counted as failures; their earlier results stay.
  Future<void> testMany(BuildContext context, List<NodeInfo> nodes) async {
    if (_testingMany || nodes.isEmpty) return;
    final strings = context.l10n;
    final carrier = carrierFor(nodes);
    final tested = [
      for (final node in nodes)
        if (state.testEndpointOf(node, carrier) != null ||
            node.endpoint == null)
          node,
    ];
    _withoutQuic
      ..clear()
      ..addAll([
        for (final node in nodes)
          if (!tested.contains(node)) node.storageKey,
      ]);
    final withoutQuic = nodes.length - tested.length;
    if (tested.isEmpty) {
      notifyListeners();
      ToastUtils.showWarning(strings.noNodeServesQuic);
      return;
    }
    _testingMany = true;
    _testProgress = 0;
    notifyListeners();
    final List<NodeVerification?> results;
    try {
      results = await state.verifyNodes(
        tested,
        carrier: carrier,
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
    final count = tested.length.toString();
    final reachable = (tested.length - failures).toString();
    final summary = [
      if (carrier == UpstreamTransport.quic)
        strings.testedOverQuic(count, reachable, failures.toString())
      else if (failures == 0)
        strings.testedNodes(count)
      else
        strings.testedReachableFailed(count, reachable, failures.toString()),
      if (withoutQuic > 0) strings.withoutQuic(withoutQuic.toString()),
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
    return '$place · ${node.endpoint?.label ?? node.addr}';
  }
}
