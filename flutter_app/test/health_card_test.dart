import 'package:maprisma/health_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a report: badge, summary, checks with step and command', (
    tester,
  ) async {
    final calls = <(String, Map)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HealthCard(
              method: 'agents.health',
              params: const {'command': 'claude'},
              tr: (k) => k,
              call: (method, params) async {
                calls.add((method, params));
                return {
                  'state': 'missing',
                  'summary': 'Not ready yet: Not signed in',
                  'checks': [
                    {
                      'state': 'ok',
                      'title': 'Installed',
                      'detail': '2.1',
                      'step': '',
                      'command': '',
                      'sign_in': '',
                    },
                    {
                      'state': 'missing',
                      'title': 'Not signed in',
                      'detail': 'A Claude account.',
                      'step': 'Sign in: claude /login',
                      'command': 'sudo pacman -S vte4',
                      'sign_in': 'claude',
                    },
                  ],
                };
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls.single.$1, 'agents.health');
    expect(find.text('Not set up'), findsOneWidget);
    expect(find.text('Not ready yet: Not signed in'), findsOneWidget);
    // Not ok: open from the start.
    expect(find.text('Sign in: claude /login'), findsOneWidget);
    expect(find.text('sudo pacman -S vte4'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsOneWidget);
  });

  testWidgets('no report: nothing shown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HealthCard(
            method: 'providers.health',
            params: const {'key': 'x'},
            tr: (k) => k,
            call: (method, params) async => {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Health'), findsNothing);
  });
}
