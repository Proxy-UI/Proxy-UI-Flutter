import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef TunCommandRunner =
    Future<String> Function(String executable, List<String> arguments);

class TunRouteProbe {
  final String destination;
  final String? interfaceName;
  final String? gateway;

  const TunRouteProbe(this.destination, this.interfaceName, this.gateway);

  bool get usesTunnel => RegExp(r'^utun\d+$').hasMatch(interfaceName ?? '');

  static TunRouteProbe parse(String destination, String output) {
    String? field(String name) {
      final match = RegExp(
        '^\\s*$name:\\s*(\\S+)\\s*\$',
        multiLine: true,
      ).firstMatch(output);
      return match?.group(1);
    }

    return TunRouteProbe(destination, field('interface'), field('gateway'));
  }
}

class TunInterfaceOwner {
  final String interfaceName;
  final int? pid;
  final String? executablePath;
  final bool isCurrentApp;

  const TunInterfaceOwner({
    required this.interfaceName,
    this.pid,
    this.executablePath,
    this.isCurrentApp = false,
  });

  static const smartVpnPath =
      '/Applications/iOA/iOA.app/Contents/SmartVPN/SmartVPN';

  bool get isSmartVpn => executablePath == smartVpnPath;
  String? get appPath => RegExp(
    r'^(/.+?\.app)/Contents/',
  ).firstMatch(executablePath ?? '')?.group(1);

  String get displayName {
    if (isCurrentApp) return 'CipherRelay';
    if (isSmartVpn) return 'iOA · SmartVPN';
    final path = executablePath;
    if (path == null) return 'Unknown process';
    final executable = path.split('/').last;
    final app = appPath?.split('/').last.replaceFirst(RegExp(r'\.app$'), '');
    return app == null || app == executable ? executable : '$app · $executable';
  }

  // Offer a command only for an identified app owner. Shared system daemons
  // do not identify a particular VPN, and must never receive a stop command.
  String? get temporaryStopCommand {
    final path = executablePath;
    if (pid == null ||
        pid! <= 1 ||
        isCurrentApp ||
        appPath == null ||
        path == null ||
        path.startsWith('/System/') ||
        path.contains('\n')) {
      return null;
    }
    final escaped = path
        .split('')
        .map(
          (character) => r'\.^$|?*+()[]{}'.contains(character)
              ? '\\$character'
              : character,
        )
        .join();
    return 'sudo /usr/bin/pkill -TERM -f '
        '${shellQuote('^$escaped([[:space:]]|\$)')}';
  }

  String? get reopenCommand {
    final app = appPath;
    if (app == null || isCurrentApp) return null;
    return '/usr/bin/open ${shellQuote(app)}';
  }

  static String shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";
}

enum TunDiagnosticArea { route, owners, process }

class TunDiagnosticIssue {
  final TunDiagnosticArea area;
  final String subject;

  const TunDiagnosticIssue(this.area, [this.subject = '']);
}

class TunDiagnosticReport {
  final List<TunRouteProbe> routes;
  final List<TunInterfaceOwner> owners;
  final List<TunDiagnosticIssue> issues;

  const TunDiagnosticReport({
    required this.routes,
    required this.owners,
    this.issues = const [],
  });

  bool get routesClear =>
      routes.length == 2 &&
      routes.every((route) => route.interfaceName != null && !route.usesTunnel);

  bool get onlyCurrentApp =>
      owners.isNotEmpty && owners.every((owner) => owner.isCurrentApp);

  static const verifyCommand =
      '/sbin/route -n get 1.1.1.1\n/sbin/route -n get 198.18.0.1';
}

/// Read-only, on-demand diagnostics. Never executes commands offered by the UI.
class MacosTunDiagnostics {
  final TunCommandRunner _run;
  final String currentExecutable;

  MacosTunDiagnostics({TunCommandRunner? run, String? currentExecutable})
    : _run = run ?? _runReadOnlyCommand,
      currentExecutable = currentExecutable ?? Platform.resolvedExecutable;

  Future<TunDiagnosticReport> collect() async {
    final issues = <TunDiagnosticIssue>[];
    Future<String> read(
      String executable,
      List<String> args,
      TunDiagnosticIssue issue,
    ) async {
      try {
        return await _run(executable, args);
      } catch (_) {
        // Do not include process arguments or arbitrary stderr in diagnostics.
        issues.add(issue);
        return '';
      }
    }

    final routes = await Future.wait([
      for (final destination in ['1.1.1.1', '198.18.0.1'])
        read(
          '/sbin/route',
          ['-n', 'get', destination],
          TunDiagnosticIssue(TunDiagnosticArea.route, destination),
        ).then((output) => TunRouteProbe.parse(destination, output)),
    ]);
    final interfaces = routes
        .where((route) => route.usesTunnel)
        .map((route) => route.interfaceName!)
        .toSet();
    if (interfaces.isEmpty) {
      return TunDiagnosticReport(routes: routes, owners: [], issues: issues);
    }

    final sockets = await read('/usr/sbin/netstat', [
      '-anv',
      '-f',
      'systm',
    ], const TunDiagnosticIssue(TunDiagnosticArea.owners));
    final ownersByInterface = parseOwners(sockets);
    final owners = <TunInterfaceOwner>[];
    for (final interface in interfaces) {
      final pid = ownersByInterface[interface];
      String? path;
      if (pid != null) {
        final output = await read('/bin/ps', [
          '-ww',
          '-p',
          '$pid',
          '-o',
          'comm=',
        ], TunDiagnosticIssue(TunDiagnosticArea.process, interface));
        final value = output.trim();
        if (value.startsWith('/') && !value.contains('\n')) path = value;
      }
      owners.add(
        TunInterfaceOwner(
          interfaceName: interface,
          pid: pid,
          executablePath: path,
          isCurrentApp: path != null && _isCurrentApp(path),
        ),
      );
    }
    return TunDiagnosticReport(routes: routes, owners: owners, issues: issues);
  }

  bool _isCurrentApp(String path) {
    if (path == currentExecutable) return true;
    final slash = currentExecutable.lastIndexOf('/');
    if (slash < 0) return false;
    return path ==
        '${currentExecutable.substring(0, slash)}/http-proxy-tun-helper';
  }

  static Map<String, int> parseOwners(String output) {
    final owners = <String, Set<int>>{};
    List<String>? header;
    for (final line in const LineSplitter().convert(output)) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.first == 'Proto') {
        header =
            fields.contains('unit') &&
                fields.contains('pid') &&
                fields.contains('name')
            ? fields
            : null;
        continue;
      }
      if (header == null ||
          fields.first != 'kctl' ||
          fields.length != header.length) {
        continue;
      }
      if (fields[header.indexOf('name')] != 'com.apple.net.utun_control') {
        continue;
      }
      final unit = int.tryParse(fields[header.indexOf('unit')]);
      final pid = int.tryParse(fields[header.indexOf('pid')]);
      if (unit == null || unit <= 0 || pid == null || pid <= 0) continue;
      // XNU names the interface utun(sc_unit - 1), not utun(sc_unit).
      // https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/if_utun.c
      owners.putIfAbsent('utun${unit - 1}', () => {}).add(pid);
    }
    return {
      for (final entry in owners.entries)
        if (entry.value.length == 1) entry.key: entry.value.single,
    };
  }

  static Future<String> _runReadOnlyCommand(
    String executable,
    List<String> arguments,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: {'LC_ALL': 'C', 'LANG': 'C'},
    );
    var timedOut = false;
    final timer = Timer(const Duration(seconds: 3), () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
    });
    try {
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.drain<void>();
      final code = await process.exitCode;
      final output = await stdout;
      await stderr;
      if (timedOut || code != 0) throw const ProcessException('diagnostic', []);
      return output;
    } finally {
      timer.cancel();
    }
  }
}
