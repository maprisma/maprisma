import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/core_client.g.dart';
import 'package:maprisma/reports_page.dart';
import 'package:maprisma/activity_log_pane.dart';
import 'package:maprisma/mic_button.dart';
import 'package:maprisma/history_import_controller.dart';
import 'package:flutter/services.dart';
import 'dart:convert';

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
      expect(reads, 2);
      expect(find.text('7 · Default'), findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 3);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Topic reports'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 3);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Log'));
      await tester.pumpAndSettle();
      expect(reads, 4);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(settings['ai_activity_log'], false);
      expect(
        find.text('Turn on the activity log to collect entries.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a draft can be regenerated and blank edit titles cannot save', (
    tester,
  ) async {
    var tab = 1;
    var generated = 0;
    final saving = Completer<Map<String, dynamic>>();
    final report = <String, dynamic>{
      'id': 1,
      'title': 'Draft',
      'from_day': '2026-11-19',
      'through_day': '2026-11-19',
      'helper': 'local-helper',
      'topics': <Object>[],
      'text': 'Finished',
      'saved_at': '2026-11-19',
      'entry_count': 1,
      'total_entries': 1,
      'capped': false,
    };
    final client = CoreClient.fromCall((method, params) async {
      switch (method) {
        case 'reports.helpers':
          return _helpers;
        case 'reports.generate':
          generated++;
          return {'task': 'task'};
        case 'tasks.status':
          return {
            'state': 'done',
            'result': {'draft_id': 'draft', 'draft': report},
          };
        case 'reports.save':
          return saving.future;
        case 'reports.list':
          return {
            'reports': [report],
          };
        case 'reports.get':
          return {'report': report};
      }
      return {};
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, setState) => ReportsPage(
              client: client,
              tr: (s) => s,
              tab: tab,
              onTab: (value) => setState(() => tab = value),
              onBack: () {},
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
    final mic = tester.widget<MicButton>(find.byType(MicButton));
    mic.controller!.value = const TextEditingValue(
      text: 'prefix suffix',
      selection: TextSelection.collapsed(offset: 7),
    );
    mic.onFinal!('inserted');
    expect(mic.controller!.text, 'prefix inserted suffix');
    expect(mic.controller!.selection.baseOffset, 'prefix inserted'.length);
    mic.onFinal!('😀' * 510);
    await tester.pump();
    expect(mic.controller!.text.runes.length, 500);
    mic.onPartial!('Listening…');
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Log'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Topic reports'));
    await tester.pumpAndSettle();
    expect(find.text('Listening…'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Generate'));
    await tester.pumpAndSettle();
    final generate = find.widgetWithText(OutlinedButton, 'Generate');
    expect(generate, findsOneWidget);
    expect(find.text('Save to library'), findsOneWidget);
    await tester.tap(generate);
    await tester.pumpAndSettle();
    expect(generated, 2);
    await tester.tap(find.widgetWithText(FilledButton, 'Save to library'));
    await tester.pump();
    expect(tester.widget<OutlinedButton>(generate).onPressed, isNull);
    saving.complete({'report': report});
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draft').last);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit title and note'));
    await tester.pumpAndSettle();
    final title = find
        .descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        )
        .first;
    await tester.enterText(title, '   ');
    await tester.pump();
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.enterText(title, 'New title');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'help lists sources with the log off and copies every section in eight languages',
    (tester) async {
      final source = {
        'source': 'agent:fixture',
        'name': 'Fixture agent',
        'supported': true,
      };
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'activitylog.report') {
          return {
            'entries': <Object>[],
            'import_sources': [source],
          };
        }
        if (method == 'help.open_manual') return {'opened': true};
        return {};
      });
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      for (final language in ['en', 'de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
        final raw = await tester.runAsync(
          () => rootBundle.loadString('assets/translations/$language.json'),
        );
        final strings = (jsonDecode(raw!) as Map).cast<String, String>();
        String tr(String key) => strings[key] ?? key;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReportsPage(
                client: client,
                tr: tr,
                tab: 0,
                onTab: (_) {},
                onBack: () {},
                settings: const {'ai_activity_log': false},
                onUpdate: (_) async {},
                localHelperReady: false,
                active: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('reports-help')));
        await tester.pumpAndSettle();
        expect(find.textContaining('Fixture agent'), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, tr('Copy')));
        await tester.pumpAndSettle();
        for (final key in [
          'The log',
          'Outside Maprisma',
          'Topic reports',
          'Library',
          'Tips',
        ]) {
          expect(copied, contains(tr(key)));
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'startup import progress is shared with the Log tab and manual collection stays available',
    (tester) async {
      final pending = Completer<Map<String, dynamic>>();
      var calls = 0;
      final history = HistoryImportController();
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'activitylog.import') {
          calls++;
          return {'task': 'import'};
        }
        if (method == 'tasks.status') return pending.future;
        if (method == 'activitylog.report') return {'entries': <Object>[]};
        return {};
      });
      unawaited(history.collect(client, auto: true));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReportsPage(
              client: client,
              tr: (s) => s,
              tab: 0,
              onTab: (_) {},
              onBack: () {},
              settings: const {'ai_activity_log': true},
              onUpdate: (_) async {},
              localHelperReady: false,
              active: true,
              historyImport: history,
            ),
          ),
        ),
      );
      await tester.pump();
      final button = find.widgetWithText(OutlinedButton, 'Collect history');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      pending.complete({
        'state': 'done',
        'result': {
          'sources': [
            {
              'name': 'Fixture',
              'sessions': 3,
              'added': 2,
              'updated': 1,
              'skipped': 0,
              'status': 'partial',
            },
          ],
          'added': 2,
          'updated': 1,
          'skipped': 0,
        },
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('3 sessions, 2 new, 1 updated'),
        findsOneWidget,
      );
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
      history.dispose();
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
  for (final leaveDuringUpdate in [false, true]) {
    testWidgets(
      'manual collection enables the required switches, leave=$leaveDuringUpdate',
      (tester) async {
        final updating = Completer<void>();
        final pageKey = GlobalKey<ReportsPageState>();
        final settings = <String, dynamic>{
          'ai_activity_log': false,
          'ai_activity_import': false,
        };
        final updates = <String>[];
        var collected = 0;
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'activitylog.report') return _emptyLog;
          if (method == 'activitylog.import') {
            collected++;
            expect(params['auto'], false);
            return {'task': 'manual'};
          }
          if (method == 'tasks.status') {
            return {
              'state': 'done',
              'result': {'sources': <Object>[]},
            };
          }
          return {};
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (_, setState) => ReportsPage(
                  key: pageKey,
                  client: client,
                  tr: (s) => s,
                  tab: 0,
                  onTab: (_) {},
                  onBack: () {},
                  settings: settings,
                  localHelperReady: false,
                  active: true,
                  onUpdate: (values) async {
                    updates.add(values.keys.single);
                    if (leaveDuringUpdate) {
                      await updating.future;
                      return;
                    }
                    setState(() => settings.addAll(values));
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final collect = find.widgetWithText(OutlinedButton, 'Collect history');
        await tester.ensureVisible(collect);
        await tester.tap(collect);
        await tester.pumpAndSettle();
        await pageKey.currentState!.showHelp();
        await tester.pumpAndSettle();
        expect(find.text('How reporting works'), findsNothing);
        await tester.tap(find.widgetWithText(FilledButton, 'Switch on'));
        await tester.pumpAndSettle();
        if (leaveDuringUpdate) {
          await tester.pumpWidget(const SizedBox());
          updating.complete();
          await tester.pumpAndSettle();
          expect(collected, 0);
          expect(tester.takeException(), isNull);
        } else {
          expect(find.byType(AlertDialog), findsOneWidget);
          await tester.tap(find.widgetWithText(FilledButton, 'Switch on'));
          await tester.pumpAndSettle();
          expect(updates, ['ai_activity_log', 'ai_activity_import']);
          expect(collected, 1);
          expect(find.byType(AlertDialog), findsNothing);
        }
      },
    );
  }
  testWidgets(
    'activity log shows live and history rows and copies the shared export text',
    (tester) async {
      const topic = 'Imported request about a project';
      final rows = [
        for (final (origin, label, hour) in [
          ('live', 'editing', '09'),
          ('live', 'testing', '10'),
          ('history', topic, '11'),
        ])
          {
            'origin': origin,
            'source': 'fixture',
            'project': 'example',
            'topic': label,
            'started_at': '2026-11-19T$hour:00:00Z',
            'duration_ms': 60000,
          },
      ];
      final client = CoreClient.fromCall((method, _) async {
        expect(method, 'activitylog.report');
        return {
          'from_day': '2026-11-13',
          'through_day': '2026-11-19',
          'entries': rows,
        };
      });
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityLogPane(
              client: client,
              tr: (text) => text,
              active: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in ['Editing', 'Writing or running tests', topic]) {
        expect(find.textContaining(text), findsOneWidget);
      }
      final tooltip = find.byTooltip("From the agent's own history");
      expect(tooltip, findsOneWidget);
      expect(
        find.descendant(of: tooltip, matching: find.byIcon(Icons.history)),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Copy'));
      await tester.pumpAndSettle();
      expect(copied, contains(topic));
      expect(copied, contains('Editing'));
      expect(copied, contains('Writing or running tests'));
      expect(copied!.split('\n'), hasLength(4));
      // Copy and TXT both consume _text(report); keep the topic in that text.
      expect(find.widgetWithText(TextButton, 'TXT'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collection confirmation translates each source key only once', (
    tester,
  ) async {
    String tr(String text) {
      expect(
        text.startsWith('translated:'),
        false,
        reason: 'Already translated key: $text',
      );
      return 'translated:$text';
    }

    final client = CoreClient.fromCall((_, _) async => _emptyLog);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReportsPage(
            client: client,
            tr: tr,
            tab: 0,
            onTab: (_) {},
            onBack: () {},
            settings: const {
              'ai_activity_log': false,
              'ai_activity_import': true,
            },
            onUpdate: (_) async {},
            localHelperReady: false,
            active: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final collect = find.widgetWithText(
      OutlinedButton,
      'translated:Collect history',
    );
    await tester.ensureVisible(collect);
    await tester.tap(collect);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('translated:AI activity log'),
      ),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'translated:Switch on'),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, 'translated:Back'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
