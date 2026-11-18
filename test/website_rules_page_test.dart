import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:proxy_ui/l10n/app_language.dart';
import 'package:proxy_ui/src/models/quic_support.dart';
import 'package:proxy_ui/src/providers/proxy_provider.dart';
import 'package:proxy_ui/src/screens/website_rules_page.dart';
import 'package:proxy_ui/src/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_proxy_service.dart';

/// Keeps rules in memory the way the native store answers.
class _Rules extends FakeProxyService {
  _Rules()
    : super(quicSupport: {'198.51.100.25:1081': const QuicSupport.at(10811)});

  final changes = <Map<String, Object?>>[];
  final rules = <String, Map<String, Object?>>{};

  @override
  Future<Map<String, dynamic>> websiteRules(Map<String, Object?> change) async {
    changes.add(change);
    final site = change['site'] as String?;
    final previous = change['previous'] as String?;
    switch (change['action']) {
      case 'set' when site == 'not a site':
        return {'Err': 'invalid_rule'};
      case 'set':
        if (previous != null && previous != site) {
          rules.remove(previous);
        }
        rules[site!] = {'site': site, 'target': change['target']};
      case 'remove':
        rules.remove(site);
    }
    return {
      'Ok': {'rules': rules.values.toList()},
    };
  }
}

void main() {
  setUp(() {
    final catalogue = sampleCatalogue();
    SharedPreferences.setMockInitialValues(
      samplePreferences(catalogue, current: catalogue.nodes[1].addr),
    );
  });

  testWidgets('a node rule pins the endpoint the editor shows', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Rules();
    late ProxyState state;
    await tester.runAsync(() async {
      state = ProxyState(service: service);
      while (!state.isInitialized) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await state.lookUpQuicSupport();
    });
    addTearDown(state.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(Colors.indigo, Brightness.light),
          home: const Scaffold(body: WebsiteRulesPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No website rules yet'), findsOneWidget);

    await tester.tap(find.text('Add rule').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not a site');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a domain'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '*.example.org:443');
    await tester.pump();
    await tester.tap(find.text('Node'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a node'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '198.51.100.25');
    await tester.pumpAndSettle();
    await tester.tap(find.text('198.51.100.25:1081').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('QUIC · 10811'));
    await tester.pumpAndSettle();
    expect(
      find.text('New connections go to 198.51.100.25:10811 over QUIC.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(service.changes.last, {
      'action': 'set',
      'site': '*.example.org:443',
      'target': {
        'action': 'node',
        'node_id': '198.51.100.25:1081',
        'host': '198.51.100.25',
        'port': 10811,
        'transport': 'quic',
      },
    });
    expect(find.text('Port 443'), findsOneWidget);
    expect(
      find.textContaining('Hong Kong · 198.51.100.25:10811'),
      findsOneWidget,
    );

    // Editing a rule can rename its site and toggle subdomain scope atomically.
    await tester.tap(find.byTooltip('Edit rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '*. All subdomains'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(service.changes.last['previous'], '*.example.org:443');
    expect(service.changes.last['site'], 'example.org:443');
    expect(service.rules.keys.single, 'example.org:443');

    await tester.tap(find.byTooltip('Delete rule'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete rule'));
    await tester.pumpAndSettle();
    expect(service.rules, isEmpty);
    expect(find.text('No website rules yet'), findsOneWidget);
  });

  testWidgets(
    'compact mobile layout and inline staleness warning render cleanly',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = _Rules()
        ..rules['media.example.tv'] = {
          'site': 'media.example.tv',
          'target': {
            'action': 'node',
            'node_id': '198.51.100.25:1081',
            'host': '198.51.100.25',
            'port': 2000,
            'transport': 'tcp',
          },
        };
      late ProxyState state;
      await tester.runAsync(() async {
        state = ProxyState(service: service);
        while (!state.isInitialized) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      addTearDown(state.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(Colors.indigo, Brightness.dark),
            home: const Scaffold(body: WebsiteRulesPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('The catalogue now lists 198.51.100.25:1081.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Add rule'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
