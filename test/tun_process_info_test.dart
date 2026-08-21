import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';
import 'package:proxy_ui/src/models/tun_process_tree.dart';

void main() {
  test('TUN process details preserve grouped PIDs and executable paths', () {
    final process = TunProcessInfo.fromJson({
      'name': 'league of legends',
      'display_name': 'League of Legends',
      'aliases': ['英雄联盟', 'LOL'],
      'installed': true,
      'pids': [120, 121],
      'executable_paths': [r'C:\Games\League of Legends.exe'],
      'instances': [
        {
          'pid': 120,
          'parent_pid': 100,
          'executable_path': r'C:\Games\League of Legends.exe',
        },
      ],
      'icon_png_base64': 'AQID',
    });

    expect(process.name, 'league of legends');
    expect(process.displayName, 'League of Legends');
    expect(process.aliases, ['英雄联盟', 'LOL']);
    expect(process.installed, isTrue);
    expect(process.pids, [120, 121]);
    expect(process.executablePaths, [r'C:\Games\League of Legends.exe']);
    expect(process.instances.single.pid, 120);
    expect(process.instances.single.parentPid, 100);
    expect(process.iconPng, [1, 2, 3]);
  });

  test(
    'TUN process forest keeps launcher descendants and cuts shell roots',
    () {
      TunProcessInfo process(
        String name,
        int pid, {
        int? parentPid,
        required String path,
      }) {
        return TunProcessInfo(
          name: name,
          pids: [pid],
          executablePaths: [path],
          instances: [
            TunProcessInstance(
              pid: pid,
              parentPid: parentPid,
              executablePath: path,
            ),
          ],
        );
      }

      final forest = buildTunProcessForest([
        process('explorer', 1, path: r'C:\Windows\explorer.exe'),
        process(
          'riotclientservices',
          10,
          parentPid: 1,
          path: r'D:\Riot Games\Riot Client\RiotClientServices.exe',
        ),
        process(
          'leagueclient',
          11,
          parentPid: 10,
          path: r'D:\Riot Games\League of Legends\LeagueClient.exe',
        ),
        process(
          'leagueclientuxrender',
          12,
          parentPid: 11,
          path: r'D:\Riot Games\League of Legends\LeagueClientUxRender.exe',
        ),
        process(
          'league of legends',
          13,
          parentPid: 11,
          path: r'D:\Riot Games\League of Legends\Game\League of Legends.exe',
        ),
      ]);

      final roots = {for (final root in forest) root.process.name: root};
      expect(roots.keys, containsAll(['explorer', 'riotclientservices']));
      final riot = roots['riotclientservices']!;
      expect(riot.children.single.process.name, 'leagueclient');
      expect(
        riot.descendants.map((node) => node.process.name),
        containsAll([
          'leagueclient',
          'leagueclientuxrender',
          'league of legends',
        ]),
      );
      expect(expandableTunProcessNames(forest), {
        'riotclientservices',
        'leagueclient',
      });
    },
  );

  test('TUN process forest does not collapse macOS apps under launchd', () {
    TunProcessInfo process(
      String name,
      int pid, {
      int? parentPid,
      required String path,
    }) {
      return TunProcessInfo(
        name: name,
        pids: [pid],
        executablePaths: [path],
        instances: [
          TunProcessInstance(
            pid: pid,
            parentPid: parentPid,
            executablePath: path,
          ),
        ],
      );
    }

    // On macOS every GUI application descends from launchd, so that edge has to
    // be cut or the picker renders one tree containing everything.
    final forest = buildTunProcessForest([
      process('launchd', 1, path: '/sbin/launchd'),
      process(
        'firefox',
        200,
        parentPid: 1,
        path: '/Applications/Firefox.app/Contents/MacOS/firefox',
      ),
      process(
        'code',
        300,
        parentPid: 1,
        path: '/Applications/Visual Studio Code.app/Contents/MacOS/Electron',
      ),
      // A genuine parent/child pair inside one application must survive.
      process(
        'code helper',
        301,
        parentPid: 300,
        path:
            '/Applications/Visual Studio Code.app/Contents/Frameworks/'
            'Code Helper.app/Contents/MacOS/Code Helper',
      ),
    ]);

    final roots = {for (final root in forest) root.process.name: root};
    expect(roots.keys, containsAll(['firefox', 'code']));
    expect(
      roots['firefox']!.children,
      isEmpty,
      reason: 'unrelated applications must not be nested under each other',
    );
    expect(roots['code']!.children.single.process.name, 'code helper');
  });

  test('TUN process search recognizes game initialisms', () {
    const process = TunProcessInfo(
      name: 'league of legends',
      displayName: 'League of Legends',
      pids: [59700],
      executablePaths: [
        r'D:\Riot Games\League of Legends\Game\League of Legends.exe',
      ],
    );

    expect(tunProcessMatchesQuery(process, 'lol'), isTrue);
    expect(tunProcessMatchesQuery(process, '英雄联盟'), isFalse);
    expect(tunProcessMatchesQuery(process, '59700'), isTrue);
    expect(tunProcessMatchesQuery(process, 'valorant'), isFalse);
  });

  test('TUN process search includes installed application aliases', () {
    const process = TunProcessInfo(
      name: 'league of legends',
      displayName: 'League of Legends',
      aliases: ['英雄联盟'],
      installed: true,
      pids: [],
      executablePaths: [r'E:\WeGameApps\英雄联盟\Game\League of Legends.exe'],
    );

    expect(tunProcessMatchesQuery(process, '英雄联盟'), isTrue);
    expect(process.pids, isEmpty);
  });
}
