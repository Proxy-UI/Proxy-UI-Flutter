import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/macos_tun_diagnostics.dart';

const socketHeader =
    'Proto Recv-Q Send-Q rhiwat shiwat pid epid unit id name\n';
const smartVpnSocket =
    'kctl 0 0 524288 524288 84184 0 5 5 com.apple.net.utun_control\n';
const helperPath =
    '/Applications/proxy_ui.app/Contents/MacOS/http-proxy-tun-helper';
const appPath = '/Applications/proxy_ui.app/Contents/MacOS/proxy_ui';

void main() {
  test('uses selected routes even when the physical default remains Wi-Fi', () {
    final probe = TunRouteProbe.parse(
      '1.1.1.1',
      'route to: 1.1.1.1\ngateway: 192.168.255.10\n  interface: utun4\n',
    );
    expect(probe.usesTunnel, isTrue);
    expect(probe.gateway, '192.168.255.10');
    expect(
      TunRouteProbe.parse('1.1.1.1', 'route: not in table').interfaceName,
      isNull,
    );
  });

  test('maps kernel control unit to interface and reads named PID column', () {
    final owners = MacosTunDiagnostics.parseOwners(
      'id flags pcbcount rcvbuf sndbuf name\n'
      '5 29 4 524288 524288 com.apple.net.utun_control\n'
      '$socketHeader$smartVpnSocket'
      'kctl 0 0 131072 2048 123 0 5 7 com.apple.netsrc\n',
    );
    expect(owners, {'utun4': 84184});
    expect(
      MacosTunDiagnostics.parseOwners(
        'Proto unit pid epid name\nkctl 7 999 0 com.apple.net.utun_control',
      ),
      {'utun6': 999},
    );
  });

  test('unknown formats, zero PIDs and ambiguous owners stay unidentified', () {
    expect(MacosTunDiagnostics.parseOwners(smartVpnSocket), isEmpty);
    expect(
      MacosTunDiagnostics.parseOwners(
        '$socketHeader'
        'kctl 0 0 524288 524288 0 0 5 5 com.apple.net.utun_control\n',
      ),
      isEmpty,
    );
    expect(
      MacosTunDiagnostics.parseOwners(
        '$socketHeader$smartVpnSocket'
        'kctl 0 0 524288 524288 17 0 5 5 com.apple.net.utun_control\n',
      ),
      isEmpty,
    );
  });

  test(
    'identifies the actual owner without reading process arguments',
    () async {
      final calls = <String>[];
      final service = MacosTunDiagnostics(
        currentExecutable: appPath,
        run: (exe, args) async {
          calls.add('$exe ${args.join(" ")}');
          if (exe == '/sbin/route') {
            return 'interface: utun4\ngateway: 192.168.255.10\n';
          }
          if (exe == '/usr/sbin/netstat') return '$socketHeader$smartVpnSocket';
          if (exe == '/bin/ps') {
            expect(args, ['-ww', '-p', '84184', '-o', 'comm=']);
            return '${TunInterfaceOwner.smartVpnPath}\n';
          }
          fail('Unexpected command: $exe');
        },
      );
      final report = await service.collect();
      expect(report.owners.single.displayName, 'iOA · SmartVPN');
      expect(report.owners.single.pid, 84184);
      expect(report.owners.single.temporaryStopCommand, contains('-TERM -f'));
      expect(
        report.owners.single.temporaryStopCommand,
        isNot(contains('84184')),
      );
      expect(
        report.owners.single.reopenCommand,
        "/usr/bin/open '/Applications/iOA/iOA.app'",
      );
      expect(report.routesClear, isFalse);
      expect(calls.length, 4);
      expect(
        calls.any((call) => call.contains('sudo') || call.contains('pkill')),
        isFalse,
      );
    },
  );

  test(
    'reused utun4 is classified as our helper instead of the previous VPN',
    () async {
      final service = MacosTunDiagnostics(
        currentExecutable: appPath,
        run: (exe, args) async => switch (exe) {
          '/sbin/route' => 'interface: utun4\ngateway: 10.0.0.1\n',
          '/usr/sbin/netstat' => '$socketHeader$smartVpnSocket',
          '/bin/ps' => helperPath,
          _ => throw StateError('unexpected command'),
        },
      );
      final report = await service.collect();
      expect(report.onlyCurrentApp, isTrue);
      expect(report.owners.single.temporaryStopCommand, isNull);
      expect(report.owners.single.reopenCommand, isNull);
      expect(report.owners.single.displayName, isNot(contains('iOA')));
    },
  );

  test(
    'a physical route does not enumerate or blame unrelated tunnel owners',
    () async {
      final service = MacosTunDiagnostics(
        run: (exe, args) async {
          expect(exe, '/sbin/route');
          return 'interface: en0\ngateway: 192.0.2.1\n';
        },
      );
      final report = await service.collect();
      expect(report.routesClear, isTrue);
      expect(report.owners, isEmpty);
    },
  );

  test('one failed route lookup never enables retry', () async {
    final report = await MacosTunDiagnostics(
      run: (exe, args) async {
        if (args.last == '198.18.0.1') throw StateError('permission denied');
        return 'interface: en0\n';
      },
    ).collect();
    expect(report.routesClear, isFalse);
    expect(report.issues, hasLength(1));
  });

  test(
    'missing owner privileges preserve route evidence without stop commands',
    () async {
      final report = await MacosTunDiagnostics(
        run: (exe, args) async {
          if (exe == '/sbin/route') return 'interface: utun7\n';
          throw StateError('not permitted');
        },
      ).collect();
      expect(report.owners.single.pid, isNull);
      expect(report.owners.single.temporaryStopCommand, isNull);
      expect(report.routesClear, isFalse);
    },
  );

  test(
    'identified third-party app commands match the escaped executable path',
    () {
      final owner = TunInterfaceOwner(
        interfaceName: 'utun8',
        pid: 23456,
        executablePath: '/Applications/Example VPN.app/Contents/MacOS/tunnel',
      );
      expect(owner.displayName, 'Example VPN · tunnel');
      expect(
        owner.temporaryStopCommand,
        r"sudo /usr/bin/pkill -TERM -f '^/Applications/Example VPN\.app/Contents/MacOS/tunnel([[:space:]]|$)'",
      );
      expect(
        owner.reopenCommand,
        "/usr/bin/open '/Applications/Example VPN.app'",
      );
      expect(
        TunInterfaceOwner(
          interfaceName: 'utun1',
          pid: 567,
          executablePath: '/System/Library/Example.app/Contents/MacOS/daemon',
        ).temporaryStopCommand,
        isNull,
      );
    },
  );

  test('unknown and system owners never receive termination commands', () {
    for (final path in [
      null,
      '/usr/libexec/nesessionmanager',
      '/tmp/SmartVPN',
      '/Applications/Another VPN.app/Contents/MacOS/daemon',
    ]) {
      expect(
        TunInterfaceOwner(
          interfaceName: 'utun4',
          executablePath: path,
        ).temporaryStopCommand,
        isNull,
      );
    }
    final owner = TunInterfaceOwner(
      interfaceName: 'utun4',
      executablePath: "/Applications/A'\$(id).app/Contents/MacOS/VPN",
    );
    expect(
      owner.reopenCommand,
      "/usr/bin/open '/Applications/A'\"'\"'\$(id).app'",
    );
  });
}
