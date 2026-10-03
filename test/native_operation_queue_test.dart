import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/ffi/native_operation_queue.dart';

void main() {
  test(
    'closing retains the handle until an in-flight isolate returns',
    () async {
      final queue = NativeOperationQueue();
      final pending = Completer<void>();
      final events = <String>[];
      final first = queue.run(() async {
        events.add('start');
        await pending.future;
        events.add('returned');
      });
      final closed = queue.close(() async => events.add('destroy'));
      await Future<void>.delayed(Duration.zero);
      expect(events, ['start']);
      await expectLater(queue.run(() async {}), throwsStateError);
      pending.complete();
      await first;
      await closed;
      await queue.close(() async => events.add('double destroy'));
      expect(events, ['start', 'returned', 'destroy']);
      expect(queue.isBusy, isFalse);
    },
  );

  test('failed calls do not strand queued work or final cleanup', () async {
    final queue = NativeOperationQueue();
    final failed = queue.run(() async => throw StateError('native failure'));
    final next = queue.run(() async => 42);
    var released = false;
    final closed = queue.close(() async => released = true);
    await expectLater(failed, throwsStateError);
    expect(await next, 42);
    await closed;
    expect(released, isTrue);
  });
}
