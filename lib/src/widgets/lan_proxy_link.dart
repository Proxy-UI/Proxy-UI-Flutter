import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_network_service.dart';
import '../utils/toast_utils.dart';

class LanProxyLink extends StatefulWidget {
  const LanProxyLink({super.key, required this.port, this.networkService});

  final int port;
  final LocalNetworkService? networkService;

  @override
  State<LanProxyLink> createState() => _LanProxyLinkState();
}

class _LanProxyLinkState extends State<LanProxyLink> {
  late LocalNetworkService _networkService;
  late Future<String?> _url;

  @override
  void initState() {
    super.initState();
    _networkService = widget.networkService ?? LocalNetworkService();
    _url = _networkService.getHttpProxyUrl(widget.port);
  }

  @override
  void didUpdateWidget(covariant LanProxyLink oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.networkService != widget.networkService) {
      _networkService = widget.networkService ?? LocalNetworkService();
    }
    if (oldWidget.port != widget.port ||
        oldWidget.networkService != widget.networkService) {
      _refresh();
    }
  }

  void _refresh() {
    setState(() {
      _url = _networkService.getHttpProxyUrl(widget.port);
    });
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ToastUtils.showSuccess('LAN proxy link copied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FutureBuilder<String?>(
      future: _url,
      builder: (context, snapshot) {
        final url = snapshot.data;
        final loading = snapshot.connectionState == ConnectionState.waiting;
        return Container(
          key: const Key('lan-proxy-link'),
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(Icons.lan_outlined, color: colors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'LAN HTTP proxy',
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      loading
                          ? 'Finding Wi-Fi address...'
                          : url ?? 'Wi-Fi address unavailable',
                      key: const Key('lan-proxy-url'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: url == null
                            ? colors.onSurfaceVariant
                            : colors.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  onPressed: url == null ? _refresh : () => _copy(url),
                  icon: Icon(
                    url == null ? Icons.refresh : Icons.content_copy_outlined,
                  ),
                  tooltip: url == null
                      ? 'Refresh Wi-Fi address'
                      : 'Copy LAN proxy link',
                ),
            ],
          ),
        );
      },
    );
  }
}
