import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_service.dart';

void main() {
  test('TUN process details preserve grouped PIDs and executable paths', () {
    final process = TunProcessInfo.fromJson({
      'name': 'league of legends',
      'pids': [120, 121],
      'executable_paths': [r'C:\Games\League of Legends.exe'],
    });

    expect(process.name, 'league of legends');
    expect(process.pids, [120, 121]);
    expect(process.executablePaths, [r'C:\Games\League of Legends.exe']);
  });
}
