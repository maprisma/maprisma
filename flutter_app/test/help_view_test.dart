import 'package:maprisma/help_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the manual opens; a viewer that does not start is said', (
    tester,
  ) async {
    var opened = 0, started = 0;
    var works = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HelpView(
            manual: true,
            tr: (k) => k,
            onOpenManual: () async {
              opened++;
              return works;
            },
            starts: [
              (
                'Your first agent',
                Icons.rocket_launch_outlined,
                () => started++,
              ),
            ],
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('help-manual')));
    await tester.pump();
    expect(opened, 1);
    expect(find.text('Could not open the manual: xdg-open'), findsOneWidget);
    works = true;
    await tester.tap(find.byKey(const ValueKey('help-manual')));
    await tester.pump();
    expect(find.textContaining('Could not open'), findsNothing);
    await tester.tap(find.text('Your first agent'));
    expect(started, 1);
  });

  testWidgets('without a manual only where to start', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HelpView(
            manual: false,
            tr: (k) => k,
            onOpenManual: () async => true,
            starts: const [],
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('User manual'), findsNothing);
    expect(find.text('Where to start'), findsOneWidget);
  });

  testWidgets('Help tabs switch to Usage and invoke secondary page callbacks', (
    tester,
  ) async {
    String? openedTab;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HelpView(
            manual: true,
            tr: (k) => k,
            onOpenManual: () async => true,
            tabs: [
              (
                'Your first agent',
                Icons.rocket_launch_outlined,
                () => openedTab = 'guide',
              ),
              ('Agents', Icons.list, () => openedTab = 'agents'),
              (
                'Providers and models',
                Icons.memory_outlined,
                () => openedTab = 'providers',
              ),
              (
                'Connections',
                Icons.account_tree_outlined,
                () => openedTab = 'connections',
              ),
            ],
            onUsage: () async => {
              'categories': [
                {
                  'plugin': 'maprisma',
                  'task': 'Smart Check',
                  'runs': 2,
                  'totals': {'tokens': 1200, 'unknown': 0},
                  'entries': [
                    {
                      'when': '2026-10-31',
                      'agent': 'claude',
                      'ok': true,
                      'tokens': 1200,
                    },
                  ],
                },
              ],
            },
            starts: const [],
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('help-tab-overview')), findsOneWidget);
    expect(find.byKey(const ValueKey('help-tab-Agents')), findsOneWidget);
    expect(find.byKey(const ValueKey('help-tab-Usage')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('help-tab-Agents')));
    expect(openedTab, 'agents');

    await tester.tap(find.byKey(const ValueKey('help-tab-Usage')));
    await tester.pumpAndSettle();
    expect(find.text('Last 30 days'), findsOneWidget);
    expect(find.text('maprisma · Smart Check'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('help-tab-overview')));
    await tester.pumpAndSettle();
    expect(find.text('User manual'), findsOneWidget);
  });
}
