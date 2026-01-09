import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/proxy_provider.dart';
import '../providers/theme_provider.dart';
import '../ffi/proxy_service.dart';

/// Log viewer page with filtering and colored entries
class LogPage extends StatelessWidget {
  const LogPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ThemeColors.get(context.watch<ThemeState>().appTheme);

    return Consumer<ProxyState>(
      builder: (context, state, _) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('SYSTEM LOGS'),
            actions: [
              _buildFilterDropdown(context, state, theme, colors),
              const SizedBox(width: smallSpacing),
              IconButton(
                onPressed: state.clearLogs,
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Clear logs',
              ),
              const SizedBox(width: smallSpacing),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(mediumSpacing),
            child: _buildLogContainer(context, state, theme, colors),
          ),
        );
      },
    );
  }

  Widget _buildFilterDropdown(
    BuildContext context,
    ProxyState state,
    ThemeData theme,
    ThemeColors colors,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: smallSpacing),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: state.minLogLevel,
          dropdownColor: theme.colorScheme.surface,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: theme.colorScheme.onSurface,
          ),
          items: List.generate(5, (index) {
            return DropdownMenuItem(
              value: index,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _getLogColor(index, theme),
                    ),
                  ),
                  const SizedBox(width: smallSpacing),
                  Text(LogLevel.getName(index)),
                ],
              ),
            );
          }),
          onChanged: (value) {
            if (value != null) state.setMinLogLevel(value);
          },
        ),
      ),
    );
  }

  Widget _buildLogContainer(
    BuildContext context,
    ProxyState state,
    ThemeData theme,
    ThemeColors colors,
  ) {
    final logs = state.filteredLogs;
    final isDark = theme.brightness == Brightness.dark;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151C28) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeOutCubic,
          child: logs.isEmpty
              ? _buildEmptyState(theme, colors)
              : ListView.builder(
                  key: ValueKey(logs.length),
                  padding: const EdgeInsets.all(mediumSpacing),
                  itemCount: logs.length,
                  reverse: true,
                  itemBuilder: (context, index) {
                    final log = logs[logs.length - 1 - index];
                    return _LogEntry(entry: log);
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.terminal,
            size: 64,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: mediumSpacing),
          Text(
            'No logs yet',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: smallSpacing),
          Text(
            'Start the proxy to see activity',
            style: TextStyle(
              fontSize: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Color _getLogColor(int level, ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    switch (level) {
      case 0:
        return isDark
            ? const Color(0xFF78909C)
            : const Color(0xFF607D8B); // TRACE
      case 1:
        return isDark
            ? const Color(0xFF64B5F6)
            : const Color(0xFF1976D2); // DEBUG
      case 2:
        return isDark
            ? const Color(0xFF81C784)
            : const Color(0xFF388E3C); // INFO
      case 3:
        return isDark
            ? const Color(0xFFFFD54F)
            : const Color(0xFFF57C00); // WARN
      case 4:
        return isDark
            ? const Color(0xFFE57373)
            : const Color(0xFFD32F2F); // ERROR
      default:
        return theme.colorScheme.onSurface.withValues(alpha: 0.5);
    }
  }
}

class _LogEntry extends StatelessWidget {
  final LogEntry entry;

  const _LogEntry({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _getLogColor(entry.level, theme);
    final time = _formatTime(entry.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: tinySpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          SizedBox(
            width: 70,
            child: Text(
              time,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          // Level badge
          Container(
            width: 50,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Text(
              entry.levelName,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: smallSpacing),
          // Message
          Expanded(
            child: SelectableText(
              entry.message,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: theme.colorScheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }

  Color _getLogColor(int level, ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    switch (level) {
      case 0:
        return isDark ? const Color(0xFF78909C) : const Color(0xFF607D8B);
      case 1:
        return isDark ? const Color(0xFF64B5F6) : const Color(0xFF1976D2);
      case 2:
        return isDark ? const Color(0xFF81C784) : const Color(0xFF388E3C);
      case 3:
        return isDark ? const Color(0xFFFFD54F) : const Color(0xFFF57C00);
      case 4:
        return isDark ? const Color(0xFFE57373) : const Color(0xFFD32F2F);
      default:
        return theme.colorScheme.onSurface.withValues(alpha: 0.5);
    }
  }
}
