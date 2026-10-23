import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/node_model.dart';
import '../../models/socks5_link.dart';
import '../../providers/proxy_provider.dart';
import '../../utils/toast_utils.dart';
import '../../widgets/link_tile.dart';
import '../../widgets/node_badges.dart';

/// The `socks5://` link of a node whose administrator enabled its SOCKS5
/// endpoint. Shows nothing for any other node.
class NodeSocks5Link extends StatefulWidget {
  const NodeSocks5Link({super.key, required this.node});

  final NodeInfo node;

  @override
  State<NodeSocks5Link> createState() => _NodeSocks5LinkState();
}

class _NodeSocks5LinkState extends State<NodeSocks5Link> {
  bool _revealed = false;

  @override
  void didUpdateWidget(covariant NodeSocks5Link oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.storageKey != widget.node.storageKey) _revealed = false;
  }

  Future<void> _copy(String url) async {
    final strings = context.l10n;
    try {
      await Clipboard.setData(ClipboardData(text: url));
      ToastUtils.showSuccess(strings.socks5LinkCopied);
    } catch (error) {
      ToastUtils.showError(strings.failedToCopy(error.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final (answered, socks5) = context.select<ProxyState, (bool, Socks5Link?)>(
      (state) => (
        state.hasSocks5Answer(widget.node),
        state.socks5LinkFor(widget.node),
      ),
    );
    // Asks once per catalogue refresh, including while the panel stays open.
    if (!answered) {
      final node = widget.node;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<ProxyState>().lookUpSocks5Link(node);
      });
    }
    if (socks5 == null) return const SizedBox.shrink();
    final strings = context.l10n;
    // The link always carries TCP; the tag names UDP only when it is relayed.
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: LinkTile(
        key: const Key('node-socks5-link'),
        icon: Icons.link,
        title: strings.socks5Link,
        tags: [if (socks5.udp) const ProtocolTag('UDP')],
        value: _revealed ? socks5.url : socks5.address,
        valueKey: const Key('node-socks5-url'),
        valueMaxLines: _revealed ? 3 : 1,
        actions: [
          IconButton(
            tooltip: _revealed
                ? strings.hideSocks5Password
                : strings.showSocks5Password,
            onPressed: () => setState(() => _revealed = !_revealed),
            icon: Icon(
              _revealed
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
          IconButton(
            tooltip: strings.copySocks5Link,
            onPressed: () => _copy(socks5.url),
            icon: const Icon(Icons.content_copy_outlined),
          ),
        ],
      ),
    );
  }
}
