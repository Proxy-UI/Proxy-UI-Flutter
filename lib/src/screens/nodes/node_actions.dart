import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/country_atlas.dart';
import '../../models/node_health.dart';
import '../../models/node_model.dart';
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
    ),
];

/// What a user can do to a node, with the feedback each action gives, shared
/// by the galaxy, the list and the dashboard so they never disagree.
class NodeActions extends ChangeNotifier {
  NodeActions(this.state);

  final ProxyState state;
  final Set<String> _switching = {};
  bool _testingMany = false;

  bool isSwitching(NodeInfo node) => _switching.contains(node.storageKey);

  bool get isSwitchingAny => _switching.isNotEmpty;

  bool get testingMany => _testingMany;

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
    notifyListeners();
    try {
      final success = await state.switchToNode(node);
      if (success) {
        ToastUtils.showSuccess(
          strings.switchedTo(_label(node, strings, language)),
        );
      } else {
        ToastUtils.showError(state.lastError ?? strings.failedToSwitchNode);
      }
    } catch (error) {
      ToastUtils.showError(strings.failedToSwitch(error.toString()));
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

  /// Test [nodes] eight at a time and report how many answered.
  Future<void> testMany(BuildContext context, List<NodeInfo> nodes) async {
    if (_testingMany || nodes.isEmpty) return;
    final strings = context.l10n;
    _testingMany = true;
    notifyListeners();
    var next = 0;
    var failures = 0;
    Future<void> worker() async {
      while (next < nodes.length) {
        final node = nodes[next++];
        final verification = await state.verifyNode(node);
        if (verification == null || !verification.isVerified) failures++;
      }
    }

    try {
      await Future.wait(
        List.generate(nodes.length < 8 ? nodes.length : 8, (_) => worker()),
      );
    } finally {
      _testingMany = false;
      notifyListeners();
    }
    if (failures == 0) {
      ToastUtils.showSuccess(strings.testedNodes(nodes.length.toString()));
    } else {
      ToastUtils.showError(
        strings.testedReachableFailed(
          nodes.length.toString(),
          (nodes.length - failures).toString(),
          failures.toString(),
        ),
      );
    }
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
    return '$place · ${node.addr}';
  }
}
