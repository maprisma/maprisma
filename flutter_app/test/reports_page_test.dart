import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/core_client.g.dart';
import 'package:maprisma/reports_page.dart';

const _emptyLog = {'entries': <Object>[]};
const _helpers = {
  'helpers': [
    {'command': 'local-helper', 'name': 'Local helper', 'local': true},
  ],
  'chosen': 'local-helper',
  'online_allowed': false,
};

void main() {
  testWidgets(
    'refreshes the log only while active and updates the shared key',
    (tester) async {
      var reads = 0;
      var tab = 0;
      final settings = <String, dynamic>{'ai_activity_log': true};
      final client = CoreClient.fromCall((method, _) async {
        if (method == 'activitylog.report') {
          reads++;
          return _emptyLog;
        }
        return _helpers;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (_, setState) => ReportsPage(
                client: client,
                tr: (text) => text,
                tab: tab,
                onTab: (value) => setState(() => tab = value),
                onBack: () {},
                settings: settings,
                onUpdate: (values) async =>
                    setState(() => settings.addAll(values)),
                localHelperReady: true,
                active: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('7 · Default'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 2);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Topic reports'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 2);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Log'));
      await tester.pumpAndSettle();
      expect(reads, 3);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(settings['ai_activity_log'], false);
      expect(
        find.text('Turn on the activity log to collect entries.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('leaving during startup waits for and cancels the task handle', (
    tester,
  ) async {
    final starting = Completer<Map<String, dynamic>>();
    String? cancelled;
    var left = false;
    final key = GlobalKey<ReportsPageState>();
    final client = CoreClient.fromCall((method, params) async {
      switch (method) {
        case 'reports.helpers':
          return _helpers;
        case 'reports.generate':
          return starting.future;
        case 'tasks.status':
          return {'state': 'running'};
        case 'tasks.cancel':
          cancelled = params['task'] as String;
          return {'state': 'stopped'};
      }
      return {};
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) => left
                ? const Text('Map')
                : ReportsPage(
                    key: key,
                    client: client,
                    tr: (text) => text,
                    tab: 1,
                    onTab: (_) {},
                    onBack: () async {
                      if (await key.currentState!.allowExit()) {
                        setState(() => left = true);
                      }
                    },
                    settings: const {},
                    onUpdate: (_) async {},
                    localHelperReady: true,
                    active: true,
                  ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Back'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel report'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(left, false);
    starting.complete({'task': 'delayed'});
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(cancelled, 'delayed');
    expect(find.text('Map'), findsOneWidget);
  });
}
