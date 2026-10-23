import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';

import '../../models/node_model.dart';
import '../../models/socks5_link.dart';
import '../../providers/proxy_provider.dart';
import '../../utils/toast_utils.dart';

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
  void initState() {
    super.initState();
    context.read<ProxyState>().lookUpSocks5Link(widget.node);
  }

  @override
  void didUpdateWidget(covariant NodeSocks5Link oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.storageKey != widget.node.storageKey) {
      _revealed = false;
      context.read<ProxyState>().lookUpSocks5Link(widget.node);
    }
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
    final socks5 = context.select<ProxyState, Socks5Link?>(
      (state) => state.socks5LinkFor(widget.node),
    );
    if (socks5 == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final strings = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        key: const Key('node-socks5-link'),
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.link, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    socks5.udp ? strings.socks5LinkWithUdp : strings.socks5Link,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    _revealed ? socks5.url : socks5.maskedUrl,
                    key: const Key('node-socks5-url'),
                    maxLines: 1,
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
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
      ),
    );
  }
}
