import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../constants.dart';
import '../providers/proxy_provider.dart';
import '../ffi/proxy_service.dart';

/// Log viewer page with search, filtering and smart scrolling
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  int _lastKnownLogCount = 0;
  int _newLogsCount = 0;
  bool _isAtBottom = true;
  bool _isOpeningLogDirectory = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // reverse=true 时，offset=0 是底部（最新日志）
    final isAtBottom = _scrollController.offset < 50;
    if (isAtBottom != _isAtBottom) {
      setState(() {
        _isAtBottom = isAtBottom;
        if (isAtBottom) _newLogsCount = 0;
      });
    }
  }

  void _scrollToBottom() {
    _scrollController.animateTo(
      0, // reverse=true 时，0 是底部
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    setState(() {
      _newLogsCount = 0;
      _isAtBottom = true;
    });
  }

  List<LogEntry> _getFilteredLogs(ProxyState state) {
    final logs = state.filteredLogs;
    if (_searchQuery.isEmpty) return logs;
    // Lower-cased once instead of once per entry, which is the difference
    // between one allocation and a thousand on every rebuild.
    final needle = _searchQuery.toLowerCase();
    return logs
        .where((e) => e.message.toLowerCase().contains(needle))
        .toList(growable: false);
  }

  void _onSearchChanged(String value) {
    setState(() => _searchQuery = value);
  }

  Future<void> _openLogDirectory(ProxyState state) async {
    if (_isOpeningLogDirectory) return;
    setState(() => _isOpeningLogDirectory = true);
    try {
      await state.openLogDirectory();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the log folder: $error')),
      );
    } finally {
      if (mounted) setState(() => _isOpeningLogDirectory = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ProxyState>(
      builder: (context, state, _) {
        // Log arrivals come through their own notifier, so a traffic burst
        // rebuilds this subtree only, and only while this page is on screen.
        return ValueListenableBuilder<int>(
          valueListenable: state.logRevision,
          builder: (context, _, _) => _buildBody(context, state),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ProxyState state) {
    final logs = _getFilteredLogs(state);

    // 检测新日志
    final currentLogCount = state.logCount;
    if (currentLogCount > _lastKnownLogCount && !_isAtBottom) {
      _newLogsCount += currentLogCount - _lastKnownLogCount;
    }
    _lastKnownLogCount = currentLogCount;

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 工具栏
            _buildToolbar(context, state, logs.length),
            const SizedBox(height: 16),
            // 日志卡片
            Expanded(
              child: Stack(
                children: [
                  Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12.0),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12.0),
                      child: _buildLogList(context, logs),
                    ),
                  ),
                  // 新日志提示按钮
                  if (_newLogsCount > 0 && !_isAtBottom)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: _buildNewLogsButton(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context, ProxyState state, int matchCount) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Row(
      children: [
        // 搜索框
        Expanded(
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            decoration: InputDecoration(
              hintText: 'Search logs (grep)...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchQuery.isNotEmpty
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$matchCount',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                        ),
                      ],
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Level 过滤（阈值，INFO+ 表示包含更高等级）
        _buildFilterDropdown(context, state, isDark),
        const SizedBox(width: 8),
        if (state.hasLocalLogStorage)
          IconButton(
            onPressed: _isOpeningLogDirectory
                ? null
                : () => _openLogDirectory(state),
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: 'Open log folder',
          ),
        // 清除按钮
        IconButton(
          onPressed: state.clearLogs,
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Clear logs',
        ),
      ],
    );
  }

  Widget _buildFilterDropdown(
    BuildContext context,
    ProxyState state,
    bool isDark,
  ) {
    return DropdownButton<int>(
      value: state.minLogLevel,
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
                  color: LogLevel.getColor(index, isDark: isDark),
                ),
              ),
              const SizedBox(width: 8),
              Text(LogLevel.getThresholdLabel(index)),
            ],
          ),
        );
      }),
      onChanged: (value) {
        if (value != null) state.setMinLogLevel(value);
      },
    );
  }

  Widget _buildNewLogsButton() {
    return FilledButton.icon(
      onPressed: _scrollToBottom,
      icon: const Icon(Icons.arrow_downward, size: 16),
      label: Text('$_newLogsCount new'),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }

  Widget _buildLogList(BuildContext context, List<LogEntry> logs) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (logs.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.terminal,
              size: 64,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty ? 'No matching logs' : 'No logs yet',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different search term'
                  : 'Start the proxy to see activity',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: logs.length,
      reverse: true,
      itemBuilder: (context, index) {
        final log = logs[logs.length - 1 - index];
        return _LogEntry(entry: log, isDark: isDark, searchQuery: _searchQuery);
      },
    );
  }
}

class _LogEntry extends StatelessWidget {
  final LogEntry entry;
  final bool isDark;
  final String searchQuery;

  const _LogEntry({
    required this.entry,
    required this.isDark,
    required this.searchQuery,
  });

  @override
  Widget build(BuildContext context) {
    final color = LogLevel.getColor(entry.level, isDark: isDark);
    final time = _formatTime(entry.timestamp);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
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
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.5),
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
          const SizedBox(width: 8),
          // Message with highlight
          Expanded(
            child: searchQuery.isEmpty
                ? SelectableText(
                    entry.message,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                      height: 1.4,
                    ),
                  )
                : _buildHighlightedText(context),
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightedText(BuildContext context) {
    final text = entry.message;
    final query = searchQuery.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final index = text.toLowerCase().indexOf(query, start);
      if (index == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (index > start) {
        spans.add(TextSpan(text: text.substring(start, index)));
      }
      spans.add(
        TextSpan(
          text: text.substring(index, index + query.length),
          style: TextStyle(
            backgroundColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.3),
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = index + query.length;
    }

    return SelectableText.rich(
      TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurface,
          height: 1.4,
        ),
        children: spans,
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}';
  }
}
