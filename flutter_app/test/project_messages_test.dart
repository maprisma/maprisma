import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'project_board_test.dart' show card, showBoard;

/// Messages to a running project (task 096): Send, Send now, the list of
/// messages with its remove symbol, the card's badge.
class Store {
  Store(this.project, {this.capabilities = const ['board', 'messages']});
  Map<String, dynamic> project;
  final List<String> capabilities;
  final sent = <Map<String, dynamic>>[];
  final dropped = <Map<String, dynamic>>[];

  /// The next `message` / `message_drop` is refused with this code.
  String? refuse;

  /// Send now's answer: continued, and the reason when not.
  bool continued = true;

  /// Send now's answer names no message (it was dropped meanwhile), or the
  /// message as delivered.
  bool noMessage = false;
  bool delivered = false;
  String? reason;

  /// The next `message` waits for this.
  Completer<void>? hold;

  /// The next `message_drop` waits for this.
  Completer<void>? holdDrop;

  /// The next `get` answers the project as it was when asked, after this.
  Completer<void>? holdGet;

  /// More projects on the board (not running into messages).
  final others = <Map<String, dynamic>>[];
  final calls = <String>[];

  List<Map<String, dynamic>> get all => [project, ...others];

  /// The card as the core counts it.
  static Map<String, dynamic> listed(Map<String, dynamic> p) => {
    ...p,
    'messages_queued': [
      for (final m in p['messages'] as List? ?? const [])
        if ((m as Map)['state'] == 'queued') m,
    ].length,
  };
}

Map<String, dynamic> running({
  String id = 'a',
  String status = 'running',
  List<Map<String, dynamic>> messages = const [],
  String? phase,
}) => {
  ...card(
    id,
    status: status,
    bucket: 'running',
    activity: 'running',
    runId: 'r1',
  ),
  'phase': ?phase,
  'messages': messages,
  'messages_queued': messages.where((m) => m['state'] == 'queued').length,
};

Future<GlobalKey<AiProjectCenterPageState>> mount(
  WidgetTester tester,
  Store store,
) async {
  final key = GlobalKey<AiProjectCenterPageState>();
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AiProjectCenterPage(
          key: key,
          tr: (s) => s,
          onCall: (op, args) async {
            store.calls.add(op);
            switch (op) {
              case 'list':
                return {
                  'projects': [for (final p in store.all) Store.listed(p)],
                  'capabilities': store.capabilities,
                };
              case 'get':
                final asked = store.all.firstWhere(
                  (p) => p['id'] == args['id'],
                );
                if (store.holdGet case final hold?) {
                  store.holdGet = null;
                  await hold.future;
                }
                return {
                  'project': {
                    ...asked,
                    'brief': 'b',
                    'plan': 'p',
                    'team': [
                      {'agent': 'claude', 'role': 'lead'},
                    ],
                    'events': asked['events'] ?? [],
                    'plan_version': 1,
                    'approved_version': 1,
                  },
                };
              case 'message':
                if (store.hold case final hold?) {
                  store.hold = null;
                  await hold.future;
                }
                if (store.refuse case final code?) {
                  store.refuse = null;
                  throw ServiceError(code);
                }
                store.sent.add(args);
                final message = {
                  'id': 'm${store.sent.length}',
                  'at': '2026-11-22T10:00:00.000Z',
                  'mode': args['mode'],
                  'text': args['text'],
                  'state': 'queued',
                  'run_id': args['run_id'],
                };
                final now = args['mode'] == 'now';
                store.project = {
                  ...store.project,
                  if (now && !store.continued) 'status': 'paused',
                  'messages': [...store.project['messages'] as List, message],
                };
                return {
                  'project': store.project,
                  'message': store.noMessage
                      ? null
                      : {...message, if (store.delivered) 'state': 'delivered'},
                  'continued': now && store.continued,
                  'reason': now && !store.continued ? store.reason : null,
                };
              case 'message_drop':
                if (store.holdDrop case final hold?) {
                  store.holdDrop = null;
                  await hold.future;
                }
                if (store.refuse case final code?) {
                  store.refuse = null;
                  throw ServiceError(code);
                }
                store.dropped.add(args);
                store.project = {
                  ...store.project,
                  'messages': [
                    for (final m in store.project['messages'] as List)
                      if ((m as Map)['id'] != args['message_id']) m,
                  ],
                };
                return {'project': store.project};
            }
            return {'profiles': [], 'runtimes': []};
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

/// Opens the project from its card and shows its Activity tab.
Future<void> openActivity(WidgetTester tester, {String id = 'a'}) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(ValueKey('project-card-$id')),
      matching: find.byKey(const ValueKey('card-open')),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(ChoiceChip, 'Activity'));
  await tester.pumpAndSettle();
}

final box = find.byKey(const ValueKey('message-text'));
final send = find.byKey(const ValueKey('message-send'));
final sendNow = find.byKey(const ValueKey('message-send-now'));
final note = find.byKey(const ValueKey('message-note'));

bool enabled(WidgetTester tester, Finder button) =>
    tester.widget<ButtonStyleButton>(button).onPressed != null;

void main() {
  testWidgets('Send queues the text with the run and clears the box', (
    tester,
  ) async {
    final store = Store(running());
    await mount(tester, store);
    await openActivity(tester);
    expect(find.text('Message to the team'), findsOneWidget);
    expect(find.text('Add instructions for the next step…'), findsOneWidget);
    // Nothing to send yet.
    expect(enabled(tester, send), isFalse);
    expect(enabled(tester, sendNow), isFalse);
    await tester.enterText(box, 'Also update the README.');
    await tester.pump();
    expect(enabled(tester, send), isTrue);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(store.sent, [
      {
        'id': 'a',
        'run_id': 'r1',
        'text': 'Also update the README.',
        'mode': 'queue',
      },
    ]);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    // The waiting message is listed with its remove symbol.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('project-message-m1')),
        matching: find.text('Also update the README.'),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Waiting for the next assignment'),
      findsOneWidget,
    );
    expect(find.byTooltip('Remove message'), findsOneWidget);
    expect(note, findsNothing);
  });

  testWidgets('a refused message keeps its text and shows why', (tester) async {
    final store = Store(running())..refuse = 'project_messages_full';
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'One more thing');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(store.sent, isEmpty);
    expect(tester.widget<TextField>(box).controller!.text, 'One more thing');
    expect(
      find.text(
        'Too many messages are waiting. Remove one or wait until the next assignment takes them.',
      ),
      findsOneWidget,
    );
    // Another run than the one shown: said for the message.
    store.refuse = 'project_changed';
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'The project moved on to another run. Look at it again, then send your message.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(box).controller!.text, 'One more thing');
  });

  testWidgets('Send now asks as Continue, then sends the acknowledgement', (
    tester,
  ) async {
    final store = Store(running());
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Stop, use the other API.');
    await tester.pump();
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    expect(find.text('Continue from saved handoff?'), findsOneWidget);
    // Cancel sends nothing and keeps the text.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(store.sent, isEmpty);
    expect(
      tester.widget<TextField>(box).controller!.text,
      'Stop, use the other API.',
    );
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'I reviewed the existing changes'),
    );
    await tester.pumpAndSettle();
    expect(store.sent, [
      {
        'id': 'a',
        'run_id': 'r1',
        'text': 'Stop, use the other API.',
        'mode': 'now',
        'acknowledge_interrupted': true,
      },
    ]);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    expect(note, findsNothing);
  });

  testWidgets('Send now that could not continue says why and that it waits', (
    tester,
  ) async {
    final store = Store(running())
      ..continued = false
      ..reason = 'project_folder_busy';
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Now please');
    await tester.pump();
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'I reviewed the existing changes'),
    );
    await tester.pumpAndSettle();
    expect(store.sent.single['mode'], 'now');
    expect(
      find.text(
        'The agent could not continue at once: Another project is working in this folder. Your message waits for the next assignment.',
      ),
      findsOneWidget,
    );
    // Stored: the box is cleared and the message listed as waiting (the
    // project is paused now, so the box itself is gone).
    expect(box, findsNothing);
    expect(find.byKey(const ValueKey('project-message-m1')), findsOneWidget);
    expect(find.byTooltip('Remove message'), findsOneWidget);
  });

  testWidgets('Ctrl+Enter sends', (tester) async {
    final store = Store(running());
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Via keyboard');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(store.sent.single['text'], 'Via keyboard');
    expect(store.sent.single['mode'], 'queue');
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
  });

  testWidgets('while pausing Send works, Send now is off', (tester) async {
    final store = Store(running(status: 'pausing'));
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Later');
    await tester.pump();
    expect(enabled(tester, send), isTrue);
    expect(enabled(tester, sendNow), isFalse);
  });

  testWidgets('planning and reviewing take messages too', (tester) async {
    for (final status in ['planning', 'reviewing']) {
      final store = Store(running(status: status));
      await mount(tester, store);
      await openActivity(tester);
      expect(box, findsOneWidget, reason: status);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('no box when the project is not running', (tester) async {
    for (final status in ['ready', 'paused', 'completed', 'failed']) {
      final store = Store(running(status: status));
      await mount(tester, store);
      await openActivity(tester);
      expect(box, findsNothing, reason: status);
      expect(find.byKey(const ValueKey('project-messages')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    }
    // Team setup is no run.
    final store = Store(running(phase: 'setup'));
    await mount(tester, store);
    await openActivity(tester);
    expect(box, findsNothing);
  });

  testWidgets('an older backend without messages shows no box', (tester) async {
    final store = Store(running(), capabilities: const ['board']);
    await mount(tester, store);
    await openActivity(tester);
    expect(find.text('Activity'), findsWidgets);
    expect(box, findsNothing);
    expect(find.byKey(const ValueKey('project-messages')), findsNothing);
  });

  testWidgets('the remove symbol drops a waiting message, also after the run', (
    tester,
  ) async {
    final store = Store(
      running(
        status: 'completed',
        messages: [
          {
            'id': 'm1',
            'at': '2026-11-22T10:00:00.000Z',
            'mode': 'queue',
            'text': 'Left over',
            'state': 'queued',
            'run_id': 'r1',
          },
        ],
      ),
    );
    await mount(tester, store);
    await openActivity(tester);
    expect(box, findsNothing);
    expect(find.text('Left over'), findsOneWidget);
    // A refusal keeps the message and says why.
    store.refuse = 'project_message_delivered';
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pumpAndSettle();
    expect(
      find.text('This message was already given to an agent.'),
      findsOneWidget,
    );
    expect(store.dropped, isEmpty);
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pumpAndSettle();
    expect(store.dropped, [
      {'id': 'a', 'message_id': 'm1'},
    ]);
    expect(find.text('Left over'), findsNothing);
  });

  testWidgets('a delivered message names its agent, role and phase', (
    tester,
  ) async {
    final store = Store(
      running(
        messages: [
          {
            'id': 'm1',
            'at': '2026-11-20T10:00:00.000Z',
            'mode': 'queue',
            'text': 'Done already',
            'state': 'delivered',
            'run_id': 'r1',
            'delivered_at': '2026-11-20T10:05:00.000Z',
            'delivered_to': {
              'phase': 'execution',
              'position': 1,
              'agent': 'codex',
              'role': 'implementer',
            },
          },
        ],
      ),
    );
    await mount(tester, store);
    await openActivity(tester);
    expect(
      find.textContaining('Delivered to codex · Implementer (Execution)'),
      findsOneWidget,
    );
    // Delivered ones cannot be removed.
    expect(find.byTooltip('Remove message'), findsNothing);
  });

  testWidgets('the card shows how many messages wait', (tester) async {
    await showBoard(tester, [
      {...card('a'), 'messages_queued': 2},
      {...card('b'), 'messages_queued': 0},
      card('c'),
    ]);
    final badge = find.byKey(const ValueKey('card-messages'));
    expect(badge, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-a')),
        matching: badge,
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('2 messages waiting'), findsOneWidget);
    await showBoard(tester, [
      {...card('a'), 'messages_queued': 1},
    ]);
    expect(find.byTooltip('1 message waiting'), findsOneWidget);
  });

  testWidgets('message events are translated', (tester) async {
    const translations = {
      'Activity': 'Aktivität',
      'Implementer': 'Umsetzung',
      'Your message was given to {0}: {1}.': 'Nachricht an {0}: {1}.',
      '{0} messages were given to {1}: {2}.': '{0} Nachrichten an {1}: {2}.',
      'The agent could not continue at once: {0} Your message waits for the next assignment.':
          'Nicht sofort: {0} Wartet.',
      'Another project is working in this folder.': 'Ordner belegt.',
      'A waiting message was removed.': 'Entfernt.',
    };
    final saved = {
      ...running(status: 'paused'),
      'brief': 'b',
      'plan': '',
      'team': [],
      'events': [
        {
          'type': 'message_delivered',
          'text': 'Your message was given to Codex: implementer.',
        },
        {
          'type': 'message_delivered',
          'text': '2 messages were given to Codex: implementer.',
        },
        {
          'type': 'message_waiting',
          'text':
              'The agent could not continue at once (project_folder_busy). Your message waits for the next assignment.',
        },
        {'type': 'message_dropped', 'text': 'A waiting message was removed.'},
      ],
    };
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiProjectCenterPage(
            tr: (key) => translations[key] ?? key,
            onCall: (op, args) async => switch (op) {
              'list' => {
                'projects': [saved],
                'capabilities': ['board', 'messages'],
              },
              'get' => {'project': saved},
              _ => {'profiles': [], 'runtimes': []},
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('card-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Aktivität'));
    await tester.pumpAndSettle();
    expect(find.text('Nachricht an Codex: Umsetzung.'), findsOneWidget);
    expect(find.text('2 Nachrichten an Codex: Umsetzung.'), findsOneWidget);
    expect(find.text('Nicht sofort: Ordner belegt. Wartet.'), findsOneWidget);
    expect(find.text('Entfernt.'), findsOneWidget);
  });

  Future<void> sendNowWith(
    WidgetTester tester,
    Store store, {
    required String? reason,
  }) async {
    store
      ..continued = false
      ..reason = reason;
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Now please');
    await tester.pump();
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'I reviewed the existing changes'),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Send now dropped meanwhile does not say it waits', (
    tester,
  ) async {
    final store = Store(running())..noMessage = true;
    await sendNowWith(tester, store, reason: 'project_message_unknown');
    expect(
      find.text(
        'Your message was removed meanwhile, so the project did not continue with it.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('waits for the next assignment'), findsNothing);
  });

  testWidgets('Send now delivered meanwhile says so', (tester) async {
    final store = Store(running())..delivered = true;
    await sendNowWith(tester, store, reason: 'project_message_delivered');
    expect(
      find.text(
        'Your message was already given to an agent meanwhile. The project did not continue a second time.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('waits for the next assignment'), findsNothing);
  });

  testWidgets('Send now overtaken by another action: the message waits', (
    tester,
  ) async {
    final store = Store(running());
    await sendNowWith(tester, store, reason: 'project_changed');
    expect(
      find.text(
        'The agent could not continue at once: Another action on this project came first. Your message waits for the next assignment.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Send now whose new agent did not start: the message waits', (
    tester,
  ) async {
    final store = Store(running());
    await sendNowWith(tester, store, reason: 'project_agent_unavailable');
    expect(
      find.text(
        'The agent could not continue at once: A selected agent is unavailable. Your message waits for the next assignment.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('while Send now waits for the new agent the page stays busy', (
    tester,
  ) async {
    final store = Store(running())..hold = Completer<void>();
    final hold = store.hold!;
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Now please');
    await tester.pump();
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'I reviewed the existing changes'),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('message-progress')), findsOneWidget);
    expect(enabled(tester, send), isFalse);
    expect(enabled(tester, sendNow), isFalse);
    // No second send: Ctrl+Enter does nothing meanwhile.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    expect(store.sent, hasLength(1));
    expect(store.sent.single['mode'], 'now');
    expect(find.byKey(const ValueKey('message-progress')), findsNothing);
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
  });

  testWidgets('a message whose agent is starting cannot be removed yet', (
    tester,
  ) async {
    final store = Store(
      running(
        messages: [
          {
            'id': 'm1',
            'at': '2026-11-22T10:00:00.000Z',
            'mode': 'queue',
            'text': 'In flight',
            'state': 'queued',
            'run_id': 'r1',
          },
        ],
      ),
    )..refuse = 'project_message_pending';
    await mount(tester, store);
    await openActivity(tester);
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This message is already in the prompt of an agent that is starting. It will be delivered there.',
      ),
      findsOneWidget,
    );
    expect(store.dropped, isEmpty);
    expect(find.text('In flight'), findsOneWidget);
  });

  Future<void> chip(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await tester.pumpAndSettle();
  }

  testWidgets('Send now ends well while another tab is shown', (tester) async {
    final store = Store(running())
      ..continued = false
      ..reason = 'project_folder_busy'
      ..hold = Completer<void>();
    final hold = store.hold!;
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Now please');
    await tester.pump();
    await tester.tap(sendNow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'I reviewed the existing changes'),
    );
    await tester.pump();
    // To the plan and back while the agent is still starting: still busy.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Plan'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Activity'));
    await tester.pump();
    expect(find.byKey(const ValueKey('message-progress')), findsOneWidget);
    expect(enabled(tester, send), isFalse);
    expect(enabled(tester, sendNow), isFalse);
    // The answer arrives while the plan is shown.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Plan'));
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    await chip(tester, 'Activity');
    expect(store.sent, hasLength(1));
    expect(find.byKey(const ValueKey('message-progress')), findsNothing);
    expect(
      find.text(
        'The agent could not continue at once: Another project is working in this folder. Your message waits for the next assignment.',
      ),
      findsOneWidget,
    );
    // The project is paused: the box is gone, the message waits.
    expect(box, findsNothing);
    expect(find.byKey(const ValueKey('project-message-m1')), findsOneWidget);
  });

  testWidgets('Send stored while another tab is shown clears its text', (
    tester,
  ) async {
    final store = Store(running())..hold = Completer<void>();
    final hold = store.hold!;
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Queued');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Goal'));
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    await chip(tester, 'Activity');
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    expect(store.sent.single['text'], 'Queued');
  });

  testWidgets('a refusal while another tab is shown is kept for the box', (
    tester,
  ) async {
    final store = Store(running())
      ..refuse = 'project_not_running'
      ..hold = Completer<void>();
    final hold = store.hold!;
    await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Too late');
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Goal'));
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    await chip(tester, 'Activity');
    expect(
      find.text('The project is not running now. Your message was not sent.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(box).controller!.text, 'Too late');
  });

  Map<String, dynamic> waiting(String id, String text) => {
    'id': id,
    'at': '2026-11-22T10:00:00.000Z',
    'mode': 'queue',
    'text': text,
    'state': 'queued',
    'run_id': 'r1',
  };

  testWidgets('a refused drop while another tab is shown keeps its reason', (
    tester,
  ) async {
    final store = Store(running(messages: [waiting('m1', 'Starting')]))
      ..refuse = 'project_message_pending'
      ..holdDrop = Completer<void>();
    final hold = store.holdDrop!;
    await mount(tester, store);
    await openActivity(tester);
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Goal'));
    await tester.pump();
    hold.complete();
    await tester.pumpAndSettle();
    await chip(tester, 'Activity');
    expect(
      find.text(
        'This message is already in the prompt of an agent that is starting. It will be delivered there.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a read older than a drop does not bring the message back', (
    tester,
  ) async {
    final store = Store(
      running(status: 'completed', messages: [waiting('m1', 'Left over')]),
    );
    final key = await mount(tester, store);
    await openActivity(tester);
    // A read that asks before the drop and answers after it.
    final hold = store.holdGet = Completer<void>();
    unawaited(key.currentState!.refresh());
    await tester.pump();
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pump();
    expect(store.dropped, hasLength(1));
    hold.complete();
    await tester.pumpAndSettle();
    expect(find.text('Left over'), findsNothing);
    // The board was read after the drop: its card has no badge any more.
    expect(
      store.calls.lastIndexOf('list'),
      greaterThan(store.calls.indexOf('message_drop')),
    );
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-messages')), findsNothing);
  });

  testWidgets('the board badge goes when the last waiting one is removed', (
    tester,
  ) async {
    final store = Store(
      running(status: 'completed', messages: [waiting('m1', 'Left over')]),
    );
    final key = await mount(tester, store);
    expect(find.byKey(const ValueKey('card-messages')), findsOneWidget);
    await openActivity(tester);
    await tester.tap(find.byTooltip('Remove message'));
    await tester.pumpAndSettle();
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-messages')), findsNothing);
  });

  testWidgets('a read older than Send does not hide the new message', (
    tester,
  ) async {
    final store = Store(running());
    final key = await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'Fresh');
    await tester.pump();
    final hold = store.holdGet = Completer<void>();
    unawaited(key.currentState!.refresh());
    await tester.pump();
    await tester.tap(send);
    await tester.pump();
    // The read after it waits, so only the older answer has come.
    final after = store.holdGet = Completer<void>();
    hold.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('project-message-m1')), findsOneWidget);
    after.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-message-m1')), findsOneWidget);
  });

  testWidgets('each project keeps its own draft', (tester) async {
    final store = Store(running());
    store.others.add({...running(id: 'b'), 'title': 'Project b'});
    final key = await mount(tester, store);
    await openActivity(tester);
    await tester.enterText(box, 'For A');
    await tester.pump();
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    await openActivity(tester, id: 'b');
    expect(tester.widget<TextField>(box).controller!.text, isEmpty);
    await tester.enterText(box, 'For B');
    await tester.pump();
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    await openActivity(tester);
    expect(tester.widget<TextField>(box).controller!.text, 'For A');
    await key.currentState!.backToBoard();
    await tester.pumpAndSettle();
    await openActivity(tester, id: 'b');
    expect(tester.widget<TextField>(box).controller!.text, 'For B');
  });

  testWidgets('message_waiting after another action and planning roles', (
    tester,
  ) async {
    final store = Store(
      running(
        status: 'paused',
        messages: [
          {
            'id': 'm1',
            'at': '2026-11-20T10:00:00.000Z',
            'mode': 'queue',
            'text': 'Planned',
            'state': 'delivered',
            'run_id': 'r1',
            'delivered_at': '2026-11-20T10:05:00.000Z',
            'delivered_to': {
              'phase': 'planning',
              'position': 1,
              'agent': 'codex',
              'role': 'implementer',
            },
          },
        ],
      ),
    );
    store.project['events'] = [
      {
        'type': 'message_waiting',
        'text':
            'The agent could not continue at once (project_changed). Your message waits for the next assignment.',
      },
    ];
    await mount(tester, store);
    await tester.tap(find.byKey(const ValueKey('card-open')));
    await tester.pumpAndSettle();
    await chip(tester, 'Activity');
    expect(
      find.textContaining('Delivered to codex · Contributor (Planning)'),
      findsOneWidget,
    );
    expect(
      find.text(
        'The agent could not continue at once: Another action on this project came first. Your message waits for the next assignment.',
      ),
      findsOneWidget,
    );
  });
}
