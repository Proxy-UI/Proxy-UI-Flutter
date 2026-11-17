import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/proxy_ffi.dart';
import 'package:proxy_ui/src/ffi/native_proxy_operations.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/services/local_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_proxy_service.dart';

class _Network extends HttpOverrides {}

class _Proxy extends FakeProxyService {
  _Proxy(this.directory);
  final Directory directory;
  @override
  Future<Map<String, dynamic>> websiteRules({Map<String, Object?>? edit}) =>
      NativeProxyOperations.shared.run(
        'site_rules',
        arguments: {'directory': directory.path, 'edit': edit},
      );

  @override
  Future<int> closeListenerSessions() async {
    calls.add('drain');
    return ProxyResult.ok;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['CIPHERRELAY_NATIVE_TEST_LIB'];
  test(
    'authenticated desktop requests use the live catalogue and provider selection',
    () async {
      DynamicLibrary.open(library!);
      final catalogue = sampleCatalogue();
      final first = catalogue.nodes.first;
      final next = catalogue.nodes.last;
      SharedPreferences.setMockInitialValues(
        samplePreferences(catalogue, current: first.addr),
      );
      final directory = await Directory.systemTemp.createTemp(
        'website-rule-profile-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final proxy = _Proxy(directory);
      final state = ProxyState(service: proxy);
      addTearDown(state.dispose);
      final initialized = Completer<void>();
      void onChange() {
        if (state.isInitialized && !initialized.isCompleted) {
          initialized.complete();
        }
      }

      state.addListener(onChange);
      onChange();
      await initialized.future;
      state.removeListener(onChange);
      final service = state.localController;
      await service.start();
      expect(service.error, isNull);
      addTearDown(service.stop);
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient()..findProxy = (_) => 'DIRECT';
        addTearDown(() => client.close(force: true));
        Future<(int, Map)> request(
          String path, {
          Map? body,
          String? token,
          String? method,
        }) async {
          final uri = Uri.http('127.0.0.1:${service.port}', '/v1/$path');
          final req = await client.openUrl(
            method ?? (body == null ? 'GET' : 'POST'),
            uri,
          );
          req.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${token ?? service.token}',
          );
          if (body != null) {
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode(body));
          }
          final response = await req.close();
          return (
            response.statusCode,
            jsonDecode(await utf8.decoder.bind(response).join()) as Map,
          );
        }

        final (_, list) = await request('nodes');
        expect(
          (list['nodes'] as List).map((n) => n['id']),
          contains(next.nodeId),
        );
        final rule = {
          'site': 'https://web.example/docs',
          'target': {
            'action': 'node',
            'node_id': next.nodeId,
            'transport': 'tcp',
          },
        };
        expect((await request('rules', method: 'PUT', body: rule)).$1, 200);
        expect(state.websiteRules.single.site, 'web.example:443');
        expect(state.websiteRules.single.endpoint?.port, next.port);
        expect((await request('rules')).$2['rules'], hasLength(1));
        expect(
          (await request(
            'rules',
            method: 'DELETE',
            body: {'site': 'web.example:443'},
          )).$2['rules'],
          isEmpty,
        );
        final selection = {
          'node_id': next.nodeId,
          'transport': 'tcp',
          'close_existing': true,
        };
        expect(
          (await request('switch', body: selection)).$2['error']['kind'],
          'not_running',
        );
        expect(await state.start(), isTrue);
        proxy.calls.clear();
        final (_, switched) = await request('switch', body: selection);
        expect(switched['active']['node_id'], next.nodeId);
        expect(state.currentNodeId, next.nodeId);
        expect(proxy.calls, ['switch ${next.host}:${next.port}', 'drain']);
        proxy.switchResult = ProxyResult.runtimeError;
        selection['node_id'] = first.nodeId;
        expect(
          (await request('switch', body: selection)).$2['error']['kind'],
          'switch_failed',
        );
        expect((await request('status')).$2['active']['node_id'], next.nodeId);
        expect(proxy.calls.where((call) => call == 'drain'), hasLength(1));

        final old = service.token!;
        await service.stop();
        await service.start();
        expect((await request('nodes', token: old)).$1, 401);
        expect((await request('status')).$1, 200);
      }, _Network());
    },
    skip: library == null || !LocalController.supported
        ? 'Requires a staged desktop native library'
        : false,
  );
}
