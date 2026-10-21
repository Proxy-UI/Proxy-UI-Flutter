import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/claude_native_proxy.dart';

import 'app_proxy_router_test.dart' show settings;

void main() {
  test('native settings preserve credentials, resume port, and restore only owned keys', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'claude-proxy-test-',
    );
    final library = Directory('${temporary.path}/Claude/configLibrary');
    final state = Directory('${temporary.path}/CipherRelay');
    await library.create(recursive: true);
    const configId = '12345678-1234-1234-1234-123456789abc';
    final file = File('${library.path}/$configId.json');
    final meta = File('${library.path}/_meta.json');
    await meta.writeAsString(
      jsonEncode({'appliedId': configId, 'entries': []}),
    );
    final original = {
      'inferenceGatewayApiKey': 'test-placeholder',
      'inferenceProvider': 'gateway',
      'egressProxyUrl': 'http://old.invalid:1234',
      'egressProxyPacUrl': 'http://old.invalid/proxy.pac',
    };
    await file.writeAsString(jsonEncode(original));
    var store = ClaudeNativeProxy(directory: state, library: library);
    addTearDown(() async {
      await store.close();
      await temporary.delete(recursive: true);
    });
    final initial = await store.save(settings(19876));
    final configured = jsonDecode(await file.readAsString()) as Map;
    final localProxy = configured['egressProxyUrl'] as String;
    expect(
      configured['inferenceGatewayApiKey'],
      original['inferenceGatewayApiKey'],
    );
    expect(configured.containsKey('egressProxyPacUrl'), isFalse);
    expect(
      await File('${state.path}/claude-native.json').readAsString(),
      isNot(contains('test-placeholder')),
    );
    await store.close();
    store = ClaudeNativeProxy(directory: state, library: library);
    await store.initialize();
    expect((await store.configuration())!.port, 19876);
    final concurrent = ClaudeNativeProxy(directory: state, library: library);
    expect((await concurrent.configuration())!.warning, isNotNull);
    await concurrent.close();
    final probe = await Socket.connect('127.0.0.1', Uri.parse(localProxy).port);
    probe.destroy();
    await store.save(settings(19877, ['.internal.example']));
    expect(
      (jsonDecode(await file.readAsString()) as Map)['egressProxyUrl'],
      localProxy,
    );
    expect((await store.configuration())!.id, initial.id);
    await store.remove();
    expect(jsonDecode(await file.readAsString()), original);
    await store.save(settings(19877));
    configured['egressProxyUrl'] = 'http://external-change.invalid:2222';
    configured['unrelatedSetting'] = 'preserve';
    await file.writeAsString(jsonEncode(configured));
    await expectLater(store.save(settings(19878)), throwsStateError);
    await store.remove();
    final restored = jsonDecode(await file.readAsString()) as Map;
    expect(restored['egressProxyUrl'], 'http://external-change.invalid:2222');
    expect(restored.containsKey('egressProxyPacUrl'), isFalse);
    expect(restored['unrelatedSetting'], 'preserve');
    expect(
      restored['inferenceGatewayApiKey'],
      original['inferenceGatewayApiKey'],
    );
    expect(await store.configuration(), isNull);
  });

  test(
    'rejects malformed metadata and profile path traversal without overwriting',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'claude-proxy-invalid-',
      );
      final library = Directory('${temporary.path}/configLibrary');
      await library.create();
      final meta = File('${library.path}/_meta.json');
      await meta.writeAsString('not JSON');
      final store = ClaudeNativeProxy(
        directory: Directory('${temporary.path}/state'),
        library: library,
      );
      addTearDown(() async {
        await store.close();
        await temporary.delete(recursive: true);
      });
      await expectLater(store.save(settings(19876)), throwsFormatException);
      expect(await meta.readAsString(), 'not JSON');
      await meta.writeAsString(jsonEncode({'appliedId': '../outside'}));
      await expectLater(store.save(settings(19876)), throwsStateError);
    },
  );
}
