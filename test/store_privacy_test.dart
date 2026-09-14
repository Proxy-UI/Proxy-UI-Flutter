import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxy_ui/src/screens/store_privacy_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('first use cannot construct services before acknowledgement', (
    tester,
  ) async {
    var applicationBuilds = 0;
    await tester.pumpWidget(
      StorePrivacyGate(
        applicationBuilder: () {
          applicationBuilds++;
          return const MaterialApp(home: Text('application'));
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(applicationBuilds, 0);
    expect(find.text('Privacy and your connection'), findsOneWidget);
    final button = find.text('I understand — continue');
    await tester.scrollUntilVisible(
      button,
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(applicationBuilds, 1);
    expect(find.text('application'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getInt(StorePrivacyGate.acknowledgementKey),
      StorePrivacyGate.policyVersion,
    );
  });

  testWidgets(
    'current acknowledgement opens app and stale acknowledgement does not',
    (tester) async {
      for (final revision in [0, StorePrivacyGate.policyVersion]) {
        SharedPreferences.setMockInitialValues({
          StorePrivacyGate.acknowledgementKey: revision,
        });
        var builds = 0;
        await tester.pumpWidget(
          StorePrivacyGate(
            key: ValueKey(revision),
            applicationBuilder: () {
              builds++;
              return const MaterialApp(home: Text('application'));
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(builds, revision == StorePrivacyGate.policyVersion ? 1 : 0);
      }
    },
  );
}
