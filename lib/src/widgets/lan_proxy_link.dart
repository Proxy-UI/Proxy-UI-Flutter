import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local_network_service.dart';
import '../utils/toast_utils.dart';

/// The addresses on offer, and the one currently shown.
typedef _LanChoices = ({List<LanAddress> addresses, LanAddress? selected});

class LanProxyLink extends StatefulWidget {
  const LanProxyLink({super.key, required this.port, this.networkService});

  final int port;
  final LocalNetworkService? networkService;

  @override
  State<LanProxyLink> createState() => _LanProxyLinkState();
}

class _LanProxyLinkState extends State<LanProxyLink> {
  late LocalNetworkService _networkService;
  late Future<_LanChoices> _choices;

  /// Kept in state so switching adapters shows the new address immediately,
  /// without waiting on the store it is also written to.
  String? _preferredAddress;

  @override
  void initState() {
    super.initState();
    _networkService = widget.networkService ?? LocalNetworkService();
    _choices = _load();
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

  Future<_LanChoices> _load() async {
    _preferredAddress ??= await _networkService.loadPreferredAddress();
    final addresses = await _networkService.listLanAddresses();
    final selected = await _networkService.resolveLanAddress(
      preferredAddress: _preferredAddress,
    );
    return (addresses: addresses, selected: selected);
  }

  void _refresh() {
    setState(() {
      _choices = _load();
    });
  }

  Future<void> _select(LanAddress address) async {
    setState(() {
      _preferredAddress = address.address;
      _choices = _load();
    });
    await _networkService.savePreferredAddress(address.address);
  }

  Future<void> _copy(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ToastUtils.showSuccess('LAN proxy link copied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return FutureBuilder<_LanChoices>(
      future: _choices,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState == ConnectionState.waiting;
        final selected = snapshot.data?.selected;
        final addresses = snapshot.data?.addresses ?? const <LanAddress>[];
        final url = selected?.httpProxyUrl(widget.port);
        // The adapter only needs naming when there is something to choose
        // between; on a single-homed machine it is noise.
        final showInterface = addresses.length > 1 && selected != null;

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
                      showInterface
                          ? 'LAN HTTP proxy · ${selected.interfaceName}'
                          : 'LAN HTTP proxy',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      loading
                          ? 'Finding LAN address...'
                          : url ?? 'LAN address unavailable',
                      key: const Key('lan-proxy-url'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
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
              else ...[
                if (addresses.length > 1)
                  PopupMenuButton<LanAddress>(
                    key: const Key('lan-proxy-picker'),
                    tooltip: 'Choose the network to share on',
                    icon: const Icon(Icons.swap_horiz),
                    onSelected: _select,
                    itemBuilder: (context) => <PopupMenuEntry<LanAddress>>[
                      for (final address in addresses)
                        CheckedPopupMenuItem<LanAddress>(
                          value: address,
                          checked: address == selected,
                          child: Text(
                            '${address.address} · ${address.interfaceName}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                IconButton(
                  onPressed: url == null ? _refresh : () => _copy(url),
                  icon: Icon(
                    url == null ? Icons.refresh : Icons.content_copy_outlined,
                  ),
                  tooltip: url == null
                      ? 'Refresh LAN address'
                      : 'Copy LAN proxy link',
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
