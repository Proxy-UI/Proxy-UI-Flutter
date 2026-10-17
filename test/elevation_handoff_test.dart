import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/services/elevation_handoff.dart';

void main() {
  test('handoff releases native state before allowing process exit', () async {
    final order = <String>[];
    expect(
      await prepareElevationExit(
        stopProxy: () async {
          order.add('stop');
          return true;
        },
        releaseTray: () async => order.add('tray'),
        flushLogs: () async => order.add('logs'),
      ),
      isTrue,
    );
    expect(order, ['stop', 'tray', 'logs']);
  });

  test('failed native cleanup keeps the tray and logs available', () async {
    final order = <String>[];
    expect(
      await prepareElevationExit(
        stopProxy: () async => false,
        releaseTray: () async => order.add('tray'),
        flushLogs: () async => order.add('logs'),
      ),
      isFalse,
    );
    expect(order, isEmpty);
  });

  for (final blockedStep in ['stop', 'tray', 'logs']) {
    test(
      'late $blockedStep completion never permits a timed-out exit',
      () async {
        final gate = Completer<void>();
        final order = <String>[];
        var exitAllowed = false;
        Future<void> step(String name) async {
          order.add(name);
          if (name == blockedStep) await gate.future;
        }

        final operation = prepareElevationExit(
          stopProxy: () async {
            await step('stop');
            return true;
          },
          releaseTray: () => step('tray'),
          flushLogs: () => step('logs'),
          timeout: const Duration(milliseconds: 20),
        ).then((ready) => exitAllowed = ready);
        await expectLater(operation, throwsA(isA<TimeoutException>()));
        final beforeLateCompletion = List<String>.of(order);
        gate.complete();
        await Future<void>.delayed(Duration.zero);
        expect(exitAllowed, isFalse);
        expect(order, beforeLateCompletion);
      },
    );
  }
}
