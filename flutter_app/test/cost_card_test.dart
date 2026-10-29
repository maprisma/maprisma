import 'package:asterism/cost_card.dart';
import 'package:asterism/settings_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the cost card asks for the euro rate once, then shows it', (
    tester,
  ) async {
    final calls = <String>[];
    var rate = false;
    Future<Map<String, dynamic>> call(String method, Map params) async {
      calls.add(method);
      return switch (method) {
        'agents.costs' => {
          'rate_due': !rate,
          'card': {
            'title': 'API cost',
            'summary': rate ? '1.20 € today' : r'$1.50 today',
            'tiles': [
              ['Today', rate ? '1.20 €' : r'$1.50', "12 % of the day's limit"],
            ],
            'models': [
              {
                'heading': 'claude-opus-5-5, last 30 days',
                'rows': [
                  ['In all', '7.20 €'],
                ],
              },
            ],
            'notes': ['An estimate.'],
          },
        },
        'costs.rate' => {'task': 't1'},
        'tasks.status' => () {
          rate = true;
          return {'state': 'done', 'result': {}};
        }(),
        _ => throw StateError(method),
      };
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CostCard(command: 'claude', call: call, tr: (t) => t),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [
      'agents.costs',
      'costs.rate',
      'tasks.status',
      'agents.costs',
    ]);
    expect(find.text('1.20 € today'), findsOneWidget);
    await tester.tap(find.text('API cost'));
    await tester.pumpAndSettle();
    expect(find.text("12 % of the day's limit"), findsOneWidget);
    expect(find.text('An estimate.'), findsOneWidget);
  });

  testWidgets('Settings › Costs: red stays above yellow', (tester) async {
    final updates = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsView(
            settings: const {
              'language': 'auto',
              'look': 'adwaita',
              'map_layers': ['agents'],
              'warn_yellow': 75,
              'warn_red': 80,
            },
            busy: false,
            tr: (key) => key,
            checkers: const [],
            unitName: 'fixture.service',
            onBack: () {},
            onUpdate: (values) async => updates.add(values),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('Yellow from'), 250);
    final yellow = tester.widget<DropdownButtonFormField<int>>(
      find.byKey(const ValueKey('warn-yellow-75')),
    );
    yellow.onChanged!(85);
    expect(updates.last, {'warn_yellow': 85, 'warn_red': 90});
    await tester.scrollUntilVisible(find.text('Red from'), 100);
    final red = tester.widget<DropdownButtonFormField<int>>(
      find.byKey(const ValueKey('warn-red-80')),
    );
    red.onChanged!(80);
    expect(updates.last, {'warn_red': 80, 'warn_yellow': 75});
    await tester.scrollUntilVisible(find.text('Currency'), -100);
    final currency = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('cost-currency-usd')),
    );
    currency.onChanged!('eur');
    expect(updates.last, {'cost_currency': 'eur'});
  });
}
