/// The one update flow: check when asked, confirm, then fetch, verify and
/// install. Nothing here runs on its own; every step starts from the user.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../services/build_capabilities.dart';
import 'release_manifest.dart';
import 'update_installers.dart';

/// Whether this build can update itself at all. Store builds and iOS are
/// updated by their store, which also forbids apps from doing it.
bool get updatesSupported =>
    !BuildCapabilities.isMacAppStore &&
    (Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux ||
        Platform.isAndroid);

enum UpdateStage {
  idle,
  checking,
  upToDate,
  available,

  /// A newer release exists, without a file for this device.
  noPackage,
  downloading,
  verifying,

  /// Handed over: the app is quitting, or the system installer is open.
  installing,

  /// Saved to Downloads for the user to unpack.
  saved,

  /// Debug builds verify everything and stop short of replacing themselves.
  verifiedOnly,
  failed,
}

/// The running build, as the update flow sees it.
class InstalledVersion {
  const InstalledVersion({
    required this.version,
    required this.build,
    required this.bundleId,
  });

  final String version;

  /// The build number; on Android the version code.
  final int build;
  final String bundleId;
}

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.proxyPort,
    required this.quit,
    this.loadInstalled = _loadInstalled,
    this.loadHost = _loadHost,
    Uri? feed,
    this.publicKey = updatePublicKey,
  }) : feed = feed ?? _debugFeed;

  /// The local proxy's port while it runs; update traffic goes through it.
  final int? Function() proxyPort;

  /// Quit through the app's normal path (proxy stopped, system settings
  /// restored). Returns only if quitting failed.
  final Future<void> Function() quit;

  final Future<InstalledVersion> Function() loadInstalled;
  final Future<UpdateHost> Function(InstalledVersion installed) loadHost;

  /// A copy of a release to update from instead of GitHub (a directory URL
  /// ending in `/`).
  final Uri? feed;

  /// The key release manifests must be signed with.
  final String publicKey;

  UpdateStage _stage = UpdateStage.idle;
  InstalledVersion? _installed;
  UpdateHost? _host;
  ReleaseManifest? _release;
  UpdatePlan? _plan;
  double _progress = 0;
  UpdateException? _failure;
  String? _savedPath;
  bool _cancelled = false;

  UpdateStage get stage => _stage;
  InstalledVersion? get installed => _installed;
  ReleaseManifest? get release => _release;
  UpdatePlan? get plan => _plan;
  double get progress => _progress;
  UpdateException? get failure => _failure;
  String? get savedPath => _savedPath;

  bool get busy =>
      _stage == UpdateStage.checking ||
      _stage == UpdateStage.downloading ||
      _stage == UpdateStage.verifying ||
      _stage == UpdateStage.installing;

  /// A release mirror for trying the flow, from `CIPHERRELAY_UPDATE_FEED`.
  /// Only honoured in debug builds.
  static Uri? get _debugFeed {
    if (!kDebugMode) return null;
    final value = Platform.environment['CIPHERRELAY_UPDATE_FEED'];
    return value == null || value.isEmpty ? null : Uri.parse(value);
  }

  /// Debug builds never replace themselves: they stop once the update is
  /// verified, so trying the flow cannot clobber a development build.
  static bool get _replaceSelf => !kDebugMode;

  void _set(UpdateStage stage) {
    _stage = stage;
    notifyListeners();
  }

  void _fail(UpdateException failure) {
    _failure = failure;
    debugPrint('Update failed: $failure');
    _set(UpdateStage.failed);
  }

  UpdateDownloader get _downloader => UpdateDownloader(proxyPort: proxyPort());

  /// Ask the newest release whether it is newer, and keep it only if its
  /// manifest is signed by the release key.
  Future<void> check() async {
    if (busy) return;
    _failure = null;
    _release = null;
    _plan = null;
    _set(UpdateStage.checking);
    try {
      final installed = _installed ??= await loadInstalled();
      final host = _host ??= await loadHost(installed);
      final downloader = _downloader;
      final manifestBytes = await downloader.bytes(
        latestManifestUrl(feed: feed),
      );
      // The version picks which signature to fetch, from that release
      // rather than "latest", so a release published in between cannot
      // pair one manifest with another's signature. It is checked below.
      final claimed = ReleaseManifest.parse(utf8.decode(manifestBytes));
      final signature = await downloader.bytes(
        releaseFileUrl(claimed.version, signatureName, feed: feed),
        limit: 4096,
      );
      final release = await verifyReleaseManifest(
        manifestBytes,
        utf8.decode(signature),
        publicKey: publicKey,
      );
      _release = release;
      if (!isNewerRelease(release, host)) {
        _set(UpdateStage.upToDate);
        return;
      }
      _plan = planUpdate(release, host);
      _set(_plan == null ? UpdateStage.noPackage : UpdateStage.available);
    } on UpdateException catch (failure) {
      _fail(failure);
    } on FormatException catch (error) {
      _fail(UpdateException(UpdateFailure.signature, error.message));
    } catch (error) {
      _fail(UpdateException(UpdateFailure.network, '$error'));
    }
  }

  /// The user confirmed: fetch, verify and apply the update.
  Future<void> start() async {
    final release = _release;
    final plan = _plan;
    final installed = _installed;
    if (release == null || plan == null || installed == null || busy) return;
    _failure = null;
    _cancelled = false;
    _progress = 0;
    _set(UpdateStage.downloading);
    Directory? work;
    try {
      work = await _workDirectory();
      final file = File(
        '${work.path}${Platform.pathSeparator}${plan.asset.name}',
      );
      await _downloader.file(
        release.assetUrl(plan.asset, feed: feed),
        file,
        expectedSize: plan.asset.size,
        cancelled: () => _cancelled,
        onProgress: (progress) {
          _progress = progress;
          notifyListeners();
        },
      );
      _set(UpdateStage.verifying);
      await verifyChecksum(file, plan.asset);
      await _apply(release, plan, installed, file, work);
    } on UpdateException catch (failure) {
      _fail(failure);
    } catch (error) {
      if (isCancellation(error)) {
        _set(UpdateStage.available);
      } else {
        _fail(UpdateException(UpdateFailure.install, '$error'));
      }
    }
  }

  void cancel() {
    if (_stage == UpdateStage.downloading) _cancelled = true;
  }

  Future<void> _apply(
    ReleaseManifest release,
    UpdatePlan plan,
    InstalledVersion installed,
    File file,
    Directory work,
  ) async {
    switch (plan.method) {
      case UpdateMethod.replaceBundle:
        final bundle = MacBundleUpdate.currentBundle();
        final staged = await MacBundleUpdate.stage(
          file,
          work,
          build: release.build,
          bundleId: installed.bundleId,
        );
        if (!_replaceSelf) {
          _set(UpdateStage.verifiedOnly);
          return;
        }
        if (!MacBundleUpdate.canReplace(bundle)) {
          // Not ours to replace: open the image for an administrator to
          // drag the new version in.
          await Process.start('/usr/bin/open', [file.path]);
          _savedPath = file.path;
          _set(UpdateStage.saved);
          return;
        }
        await MacBundleUpdate.handOff(staged, bundle, pid);
        _set(UpdateStage.installing);
        await quit();
        // Still here: quitting failed and the helper will give up untouched.
        throw const UpdateException(
          UpdateFailure.install,
          'The app did not quit',
        );
      case UpdateMethod.installer:
        if (!_replaceSelf) {
          _set(UpdateStage.verifiedOnly);
          return;
        }
        await WindowsInstallerUpdate.handOff(file, pid);
        _set(UpdateStage.installing);
        await quit();
        throw const UpdateException(
          UpdateFailure.install,
          'The app did not quit',
        );
      case UpdateMethod.systemInstaller:
        if (!await AndroidPackageUpdate.canInstall()) {
          await AndroidPackageUpdate.openInstallSettings();
          throw const UpdateException(UpdateFailure.permission);
        }
        await AndroidPackageUpdate.install(file);
        _set(UpdateStage.installing);
      case UpdateMethod.saveDownload:
        final downloads = await getDownloadsDirectory();
        final saved = await saveToDownloads(
          file,
          downloads ??
              Directory(
                '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? work.path}'
                '${Platform.pathSeparator}Downloads',
              ),
          plan.asset.name,
        );
        _savedPath = saved.path;
        _set(UpdateStage.saved);
    }
  }

  static Future<Directory> _workDirectory() async {
    final base = Platform.isAndroid
        ? await getTemporaryDirectory()
        : Directory.systemTemp;
    return base.createTemp('cipherrelay-update-');
  }

  static Future<InstalledVersion> _loadInstalled() async {
    final info = await PackageInfo.fromPlatform();
    return InstalledVersion(
      version: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
      bundleId: info.packageName,
    );
  }

  static Future<UpdateHost> _loadHost(InstalledVersion installed) async =>
      UpdateHost(
        os: Platform.operatingSystem,
        build: installed.build,
        windowsInstalled:
            Platform.isWindows && WindowsInstallerUpdate.isInstalled(),
        androidAbis: Platform.isAndroid
            ? await AndroidPackageUpdate.abis()
            : const [],
      );
}
