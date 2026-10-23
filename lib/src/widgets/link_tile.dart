import 'package:flutter/material.dart';

/// A link someone can paste into another client: what it is, the link on
/// one line, and the buttons that act on it. The LAN proxy and a node's
/// SOCKS5 endpoint both use it, so the two read and behave alike.
class LinkTile extends StatelessWidget {
  const LinkTile({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.valueKey,
    this.valueMaxLines = 1,
    this.tags = const [],
    this.actions = const [],
    this.muted = false,
  });

  final IconData icon;
  final String title;

  /// The link itself, or a status line while there is none.
  final String value;
  final Key? valueKey;

  /// More than one line for a value that is read in full, such as a link
  /// shown with its password.
  final int valueMaxLines;

  /// Small tags after the title, such as the protocols the link carries.
  final List<Widget> tags;
  final List<Widget> actions;

  /// Draws [value] as a status rather than a link.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    for (final tag in tags) ...[const SizedBox(width: 6), tag],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  key: valueKey,
                  maxLines: valueMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: muted ? colors.onSurfaceVariant : colors.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}
