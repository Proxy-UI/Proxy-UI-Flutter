import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/proxy_provider.dart';
import '../services/tray_service.dart';
import '../theme/app_theme.dart';
import 'release_manifest.dart';
import 'update_controller.dart';

/// The only way into an update: a button the user presses. It opens the
/// dialog, which checks once; nothing is fetched otherwise.
class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!updatesSupported) return const SizedBox.shrink();
    return IconButton(
      key: const Key('check-for-updates'),
      tooltip: context.l10n.checkForUpdates,
      icon: const Icon(Icons.system_update_alt),
      onPressed: () => UpdateDialog.show(context),
    );
  }
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.controller});

  final UpdateController controller;

  static Future<void> show(BuildContext context) {
    final proxy = context.read<ProxyState>();
    final controller = UpdateController(
      proxyPort: () => proxy.isRunning ? proxy.config.localPort : null,
      quit: () => TrayService.instance.quit(proxy),
    );
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(controller: controller),
    ).whenComplete(controller.dispose);
  }

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  UpdateController get _update => widget.controller;

  @override
  void initState() {
    super.initState();
    // The button the user pressed is the request to check.
    _update.check();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _update,
      builder: (context, _) => AlertDialog(
        icon: const Icon(Icons.system_update_alt),
        title: Text(context.l10n.checkForUpdates),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 320, maxWidth: 440),
          child: _body(context),
        ),
        actions: _actions(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final strings = context.l10n;
    final installed = _update.installed;
    final release = _update.release;
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final children = <Widget>[
      if (installed != null)
        Text(
          strings.updateInstalledVersion(
            installed.version,
            '${installed.build}',
          ),
          style: muted,
        ),
      const SizedBox(height: 16),
    ];
    switch (_update.stage) {
      case UpdateStage.idle:
      case UpdateStage.checking:
        children.addAll([
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(strings.updateChecking),
        ]);
      case UpdateStage.upToDate:
        children.add(
          _Status(
            icon: Icons.check_circle,
            color: StatusColors.of(context).good,
            text: strings.updateUpToDate,
          ),
        );
      case UpdateStage.available:
        final plan = _update.plan!;
        children.addAll([
          Text(
            strings.updateAvailable(release!.version),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.updateDownloadSize(_size(plan.asset.size)),
            style: muted,
          ),
          Text(plan.asset.name, style: muted),
          const SizedBox(height: 12),
          Text(switch (plan.method) {
            UpdateMethod.replaceBundle => strings.updateNoteReplace,
            UpdateMethod.installer => strings.updateNoteInstaller,
            UpdateMethod.systemInstaller => strings.updateNoteAndroid,
            UpdateMethod.saveDownload => strings.updateNoteSave,
          }),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => _open(release.page),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: Text(strings.updateReleaseNotes),
            ),
          ),
        ]);
      case UpdateStage.noPackage:
        children.add(Text(strings.updateNoPackage(release!.version)));
      case UpdateStage.downloading:
        children.addAll([
          LinearProgressIndicator(value: _update.progress),
          const SizedBox(height: 12),
          Text(strings.updateDownloading((_update.progress * 100).floor())),
          const SizedBox(height: 4),
          Text(
            '${_size(_update.receivedBytes)} / ${_size(_update.plan!.asset.size)}'
            ' · ${_size(_update.bytesPerSecond.round())}/s',
            style: muted,
          ),
        ]);
      case UpdateStage.verifying:
        children.addAll([
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(strings.updateVerifying),
        ]);
      case UpdateStage.installing:
        children.addAll([
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(
            Platform.isAndroid
                ? strings.updateInstallingAndroid
                : strings.updateInstallingDesktop,
          ),
        ]);
      case UpdateStage.saved:
        children.add(
          _Status(
            icon: Icons.download_done,
            color: StatusColors.of(context).good,
            text: strings.updateSaved(_update.savedPath ?? ''),
          ),
        );
      case UpdateStage.verifiedOnly:
        children.add(
          _Status(
            icon: Icons.verified_outlined,
            color: StatusColors.of(context).good,
            text: strings.updateVerifiedOnly,
          ),
        );
      case UpdateStage.failed:
        children.add(
          _Status(
            icon: Icons.error_outline,
            color: scheme.error,
            text: switch (_update.failure?.kind) {
              UpdateFailure.network || null => strings.updateFailedNetwork,
              UpdateFailure.signature => strings.updateFailedSignature,
              UpdateFailure.checksum => strings.updateFailedChecksum,
              UpdateFailure.verification => strings.updateFailedVerification,
              UpdateFailure.install ||
              UpdateFailure.noPackage => strings.updateFailedInstall,
              UpdateFailure.permission => strings.updateFailedPermission,
            },
          ),
        );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  List<Widget> _actions(BuildContext context) {
    final strings = context.l10n;
    void close() => Navigator.of(context).pop();
    final release = _update.release;
    return switch (_update.stage) {
      UpdateStage.available => [
        TextButton(onPressed: close, child: Text(strings.cancel)),
        FilledButton.icon(
          key: const Key('start-update'),
          onPressed: _update.start,
          icon: const Icon(Icons.download),
          label: Text(strings.updateNow),
        ),
      ],
      UpdateStage.downloading => [
        TextButton(onPressed: _update.cancel, child: Text(strings.cancel)),
      ],
      UpdateStage.checking ||
      UpdateStage.verifying ||
      UpdateStage.installing => const [],
      UpdateStage.noPackage => [
        TextButton(onPressed: close, child: Text(strings.close)),
        FilledButton(
          onPressed: () => _open(release!.page),
          child: Text(strings.updateOpenReleasePage),
        ),
      ],
      UpdateStage.failed => [
        if (release != null)
          TextButton(
            onPressed: () => _open(release.page),
            child: Text(strings.updateOpenReleasePage),
          ),
        TextButton(onPressed: close, child: Text(strings.close)),
        FilledButton(
          onPressed: _update.plan != null ? _update.start : _update.check,
          child: Text(strings.retry),
        ),
      ],
      _ => [FilledButton(onPressed: close, child: Text(strings.close))],
    };
  }

  Future<void> _open(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  static String _size(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _Status extends StatelessWidget {
  const _Status({required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: color),
      const SizedBox(width: 12),
      Expanded(child: SelectableText(text)),
    ],
  );
}
