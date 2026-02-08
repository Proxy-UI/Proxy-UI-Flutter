import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/constants.dart';

void main() {
  group('LogLevel', () {
    test('includes behaves as threshold filter', () {
      expect(
        LogLevel.includes(threshold: LogLevel.info, entryLevel: LogLevel.info),
        isTrue,
      );
      expect(
        LogLevel.includes(threshold: LogLevel.info, entryLevel: LogLevel.warn),
        isTrue,
      );
      expect(
        LogLevel.includes(threshold: LogLevel.info, entryLevel: LogLevel.error),
        isTrue,
      );
      expect(
        LogLevel.includes(threshold: LogLevel.info, entryLevel: LogLevel.debug),
        isFalse,
      );
      expect(
        LogLevel.includes(threshold: LogLevel.warn, entryLevel: LogLevel.info),
        isFalse,
      );
    });

    test('getThresholdLabel formats non-error levels with plus suffix', () {
      expect(LogLevel.getThresholdLabel(LogLevel.trace), 'TRACE+');
      expect(LogLevel.getThresholdLabel(LogLevel.debug), 'DEBUG+');
      expect(LogLevel.getThresholdLabel(LogLevel.info), 'INFO+');
      expect(LogLevel.getThresholdLabel(LogLevel.warn), 'WARN+');
      expect(LogLevel.getThresholdLabel(LogLevel.error), 'ERROR');
    });

    test('normalize clamps out-of-range levels', () {
      expect(LogLevel.normalize(-5), LogLevel.trace);
      expect(LogLevel.normalize(999), LogLevel.error);
    });
  });
}
