import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/windows_storage_migration.dart';

void main() {
  late Directory root;
  late Directory source;
  late Directory destination;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('proxy-storage-test-');
    source = await Directory('${root.path}/CipherRelay').create();
    destination = Directory('${root.path}/proxy_ui');
  });
  tearDown(() async => root.delete(recursive: true));

  Future<void> write(Directory dir, String name, String value) =>
      File('${dir.path}/$name').writeAsString(value).then((_) {});

  test(
    'copies preferences and their DNS generation without changing source',
    () async {
      const preferences = r'{"flutter.proxy_config":"{\"localPort\":10811}"}';
      const mappings =
          '{"type":"mapping","ip":"198.19.0.1","name":"example.test"}\n';
      await write(source, 'shared_preferences.json', preferences);
      await write(source, 'tun-virtual-dns-v1.jsonl', mappings);
      await write(source, 'unrelated.txt', 'do not migrate');
      await destination.create(); // path_provider's empty placeholder
      expect(
        await WindowsStorageMigration.copyIfEmpty(
          source: source,
          destination: destination,
        ),
        isTrue,
      );
      for (final name in [
        'shared_preferences.json',
        'tun-virtual-dns-v1.jsonl',
      ]) {
        expect(
          await File('${destination.path}/$name').readAsBytes(),
          await File('${source.path}/$name').readAsBytes(),
        );
      }
      expect(await File('${destination.path}/unrelated.txt').exists(), isFalse);
      expect(
        await WindowsStorageMigration.copyIfEmpty(
          source: source,
          destination: destination,
        ),
        isFalse,
      );
    },
  );

  test('existing legacy data wins and conflicting Fake-IP journals are never merged', () async {
    await destination.create();
    for (final dir in [source, destination]) {
      await write(dir, 'shared_preferences.json', '{}');
      await write(
        dir,
        'tun-virtual-dns-v1.jsonl',
        dir == source ? 'new-domain' : 'old-domain',
      );
    }
    expect(
      await WindowsStorageMigration.copyIfEmpty(
        source: source,
        destination: destination,
      ),
      isFalse,
    );
    expect(
      await File('${destination.path}/tun-virtual-dns-v1.jsonl').readAsString(),
      'old-domain',
    );
    expect(
      await File('${source.path}/tun-virtual-dns-v1.jsonl').readAsString(),
      'new-domain',
    );
  });

  test(
    'partial legacy state is preserved instead of combining generations',
    () async {
      await destination.create();
      await write(destination, 'tun-virtual-dns-v1.jsonl', 'existing');
      await write(source, 'shared_preferences.json', '{}');
      expect(
        await WindowsStorageMigration.copyIfEmpty(
          source: source,
          destination: destination,
        ),
        isFalse,
      );
      expect(
        await File('${destination.path}/shared_preferences.json').exists(),
        isFalse,
      );
    },
  );

  test(
    'invalid source preferences leave destination and source intact',
    () async {
      await write(source, 'shared_preferences.json', 'not JSON');
      await expectLater(
        WindowsStorageMigration.copyIfEmpty(
          source: source,
          destination: destination,
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      expect(
        await File('${source.path}/shared_preferences.json').readAsString(),
        'not JSON',
      );
    },
  );
}
