import 'review_test_host.dart';
import 'package:asterism/first_agent_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final route = {
    'id': 'fixture-online',
    'kind': 'online',
    'title': 'Fixture online',
    'access': 'Test account',
    'command': 'fixture',
    'verified': false,
    'steps': [
      {
        'title': 'A test question',
        'done': false,
        'detail': 'Test the agent',
        'action': 'verify',
      },
    ],
  };
  testWidgets('guide selects known routes and sends only named step actions', (
    tester,
  ) async {
    String? chosen;
    List<String>? action;
    Widget view(String? selected) => MaterialApp(
      home: Scaffold(
        body: FirstAgentView(
          data: {
            'routes': [route],
            'selected': selected,
          },
          busy: false,
          tr: (key) => key,
          onChoose: (id) => chosen = id,
          onAction: (command, name) => action = [command, name],
          onBack: () {},
          onRefresh: () {},
        ),
      ),
    );
    await tester.pumpWidget(view(null));
    await tester.tap(find.text('Fixture online'));
    expect(chosen, 'fixture-online');
    await tester.pumpWidget(view('fixture-online'));
    await tester.tap(find.text('Send the test question'));
    expect(action, ['fixture', 'verify']);
  });

  testWidgets('agent action shows command and kept data before confirmation', (
    tester,
  ) async {
    bool? accepted;
    final plan = {
      'action': 'uninstall',
      'name': 'Fixture',
      'external': true,
      'note': '',
      'url': '',
      'commands': ['mise uninstall fixture'],
      'data': ['~/fixture-data'],
      'runnable': true,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('review'),
              onPressed: () async {
                accepted = await confirmAgentAction(
                  context,
                  plan,
                  (key) => key,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    expect(find.text('mise uninstall fixture'), findsOneWidget);
    expect(find.text('What stays: ~/fixture-data'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });
}
