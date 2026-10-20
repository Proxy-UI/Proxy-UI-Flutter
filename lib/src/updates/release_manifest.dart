/// What a release offers, as its signed manifest describes it, and which of
/// its files this installation should take.
library;

import 'dart:convert';

import 'native_update_transport.dart';

/// The repository whose releases are this app's updates.
const String updateRepository = 'Proxy-UI/Proxy-UI-Flutter';

/// The Ed25519 key release manifests are signed with (raw, base64). Its
/// private half lives only in the repository's `UPDATE_SIGNING_KEY` secret and
/// the maintainer's backup; `scripts/update_signing_key.pub.pem` is the same
/// key for the release workflow.
const String updatePublicKey = 'pOlycNvXVhNApma7ahALNru9/07cIPmtEZ5EFEuMfUY=';

const String manifestName = 'release-manifest.json';
const String signatureName = 'release-manifest.json.sig';

/// Why an update could not go ahead. The dialog words it from [kind].
class UpdateException implements Exception {
  const UpdateException(this.kind, [this.detail]);

  final UpdateFailure kind;

  /// The underlying error, for the log line under the message.
  final String? detail;

  @override
  String toString() => detail == null ? kind.name : '${kind.name}: $detail';
}

enum UpdateFailure {
  network,
  signature,
  checksum,
  noPackage,
  verification,
  install,
  permission,
}

/// One downloadable file of a release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.size,
    required this.sha256,
    this.platform,
    this.abis = const [],
    this.versionCode,
  });

  final String name;
  final int size;

  /// Lower-case hex.
  final String sha256;

  /// `android` for the locally signed packages; desktop files carry none.
  final String? platform;

  /// The Android ABIs a package is built for.
  final List<String> abis;

  /// The Android version code a package installs.
  final int? versionCode;

  static ReleaseAsset fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final size = json['size'];
    final sha256 = json['sha256'];
    if (name is! String || size is! int || sha256 is! String) {
      throw const FormatException('Asset is missing its name, size or hash');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
      throw FormatException('Asset $name has a malformed hash');
    }
    // A name is a path segment of the download URL and a file name on disk.
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) {
      throw FormatException('Asset name $name is not a plain file name');
    }
    final abis = json['abis'];
    final code = json['version_code'];
    return ReleaseAsset(
      name: name,
      size: size,
      sha256: sha256,
      platform: json['platform'] as String?,
      abis: abis is List ? abis.whereType<String>().toList() : const [],
      versionCode: code is int ? code : null,
    );
  }
}

/// A release's manifest, trusted only after [verifyReleaseManifest].
class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.build,
    required this.assets,
  });

  final String version;
  final int build;
  final List<ReleaseAsset> assets;

  static ReleaseManifest parse(String text) {
    final json = jsonDecode(text);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Manifest is not an object');
    }
    final version = json['version'];
    final build = int.tryParse('${json['build']}');
    final assets = json['assets'];
    if (version is! String ||
        !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build == null ||
        assets is! List) {
      throw const FormatException('Manifest is missing its version or assets');
    }
    return ReleaseManifest(
      version: version,
      build: build,
      assets: [
        for (final asset in assets)
          if (asset is Map<String, dynamic>) ReleaseAsset.fromJson(asset),
      ],
    );
  }

  /// Where [asset] of this release downloads from.
  Uri assetUrl(ReleaseAsset asset, {Uri? feed}) =>
      releaseFileUrl(version, asset.name, feed: feed);

  Uri get page =>
      Uri.https('github.com', '/$updateRepository/releases/tag/v$version');
}

/// [name] in the release tagged `v[version]`, or under [feed] when testing
/// against a local copy of a release.
Uri releaseFileUrl(String version, String name, {Uri? feed}) => feed != null
    ? feed.resolve(name)
    : Uri.https(
        'github.com',
        '/$updateRepository/releases/download/v$version/$name',
      );

/// The newest release's manifest, before it is trusted.
Uri latestManifestUrl({Uri? feed}) => feed != null
    ? feed.resolve(manifestName)
    : Uri.https(
        'github.com',
        '/$updateRepository/releases/latest/download/$manifestName',
      );

/// Parse [manifest] only if [signature] (base64) is a valid Ed25519
/// signature of its exact bytes by [publicKey].
Future<ReleaseManifest> verifyReleaseManifest(
  List<int> manifest,
  String signature, {
  String publicKey = updatePublicKey,
  UpdateTransport? transport,
}) async {
  await (transport ?? NativeUpdateTransport.shared).start({
    'operation': 'verify_signature',
    'body': base64Encode(manifest),
    'signature': signature,
    'public_key': publicKey,
  }).result;
  try {
    return ReleaseManifest.parse(utf8.decode(manifest));
  } on FormatException catch (error) {
    throw UpdateException(UpdateFailure.signature, error.message);
  }
}

/// How an update reaches this installation.
enum UpdateMethod {
  /// Replace the application bundle and reopen it (macOS).
  replaceBundle,

  /// Run the installer quietly and reopen the app (Windows, installed).
  installer,

  /// Hand the package to the system installer (Android).
  systemInstaller,

  /// Save the archive for the user to unpack (portable Windows, Linux).
  saveDownload,
}

/// What this installation is, as far as choosing an update goes.
class UpdateHost {
  const UpdateHost({
    required this.os,
    required this.build,
    this.windowsInstalled = false,
    this.androidAbis = const [],
  });

  /// `macos`, `windows`, `linux` or `android`.
  final String os;

  /// The running build number; on Android the version code.
  final int build;

  /// Whether the Windows app was set up by the installer (rather than
  /// unpacked from the portable archive).
  final bool windowsInstalled;

  /// Supported ABIs, most preferred first.
  final List<String> androidAbis;
}

/// The file to fetch and how to apply it.
class UpdatePlan {
  const UpdatePlan(this.asset, this.method);

  final ReleaseAsset asset;
  final UpdateMethod method;
}

/// The file of [manifest] meant for [host], or null when the release has
/// none (an Android package not attached yet, an architecture not built).
UpdatePlan? planUpdate(ReleaseManifest manifest, UpdateHost host) {
  ReleaseAsset? named(String suffix) {
    for (final asset in manifest.assets) {
      if (asset.platform == null && asset.name.endsWith(suffix)) return asset;
    }
    return null;
  }

  switch (host.os) {
    case 'macos':
      final dmg = named('-macos-universal.dmg');
      return dmg == null ? null : UpdatePlan(dmg, UpdateMethod.replaceBundle);
    case 'windows':
      final file = host.windowsInstalled
          ? named('-windows-x64-setup.exe')
          : named('-windows-x64.zip');
      if (file == null) return null;
      return UpdatePlan(
        file,
        host.windowsInstalled
            ? UpdateMethod.installer
            : UpdateMethod.saveDownload,
      );
    case 'linux':
      final archive = named('-linux-x64.tar.gz');
      return archive == null
          ? null
          : UpdatePlan(archive, UpdateMethod.saveDownload);
    case 'android':
      for (final abi in host.androidAbis) {
        for (final asset in manifest.assets) {
          if (asset.platform == 'android' &&
              asset.versionCode != null &&
              asset.abis.contains(abi)) {
            return UpdatePlan(asset, UpdateMethod.systemInstaller);
          }
        }
      }
      return null;
  }
  return null;
}

/// Whether [manifest] is newer than what [host] runs. Android compares the
/// version code of the package it would install, which carries the ABI.
bool isNewerRelease(ReleaseManifest manifest, UpdateHost host) {
  if (host.os == 'android') {
    final plan = planUpdate(manifest, host);
    final code = plan?.asset.versionCode;
    if (code != null) return code > host.build;
    // No package for this device yet: newer by build, but nothing to install.
    return manifest.build > host.build % 1000;
  }
  return manifest.build > host.build;
}
