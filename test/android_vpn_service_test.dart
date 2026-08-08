import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/android_vpn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.proxy-ui/vpn-apps');
  late AndroidVpnService service;

  setUp(() {
    service = AndroidVpnService.forTesting(channel);
  });

  tearDown(() async {
    await service.disposeForTesting();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('installed application catalog is cached until refresh', () async {
    var catalogRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'listInstalledApps');
          catalogRequests++;
          return [
            {
              'packageName': 'com.example.game',
              'label': 'Example Game',
              'system': false,
            },
          ];
        });

    final first = await service.listInstalledApps();
    final second = await service.listInstalledApps();
    final refreshed = await service.listInstalledApps(forceRefresh: true);

    expect(first.single.packageName, 'com.example.game');
    expect(second.single.label, 'Example Game');
    expect(refreshed.single.isSystem, isFalse);
    expect(catalogRequests, 2);
  });

  test('visible icon requests are batched and cached', () async {
    var iconRequests = 0;
    var requestedPackages = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'loadAppIcons');
          iconRequests++;
          final arguments = call.arguments as Map<Object?, Object?>;
          requestedPackages = (arguments['packages'] as List<Object?>)
              .whereType<String>()
              .toList();
          return {
            'com.example.one': Uint8List.fromList([1, 2, 3]),
            'com.example.two': Uint8List.fromList([4, 5, 6]),
          };
        });

    final first = service.loadApplicationIcon('com.example.one');
    final second = service.loadApplicationIcon('com.example.two');
    final icons = await Future.wait([first, second]);

    expect(iconRequests, 1);
    expect(requestedPackages, ['com.example.one', 'com.example.two']);
    expect(icons.first, orderedEquals([1, 2, 3]));
    expect(icons.last, orderedEquals([4, 5, 6]));

    expect(
      await service.loadApplicationIcon('com.example.one'),
      orderedEquals([1, 2, 3]),
    );
    expect(iconRequests, 1);
  });
}
