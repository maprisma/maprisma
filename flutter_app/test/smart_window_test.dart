import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/backend.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/overlay_window.dart';
import 'package:maprisma/voice_input.dart';
import 'package:maprisma/mic_button.dart';

void main() {
  const helpers = [
    {'command': 'a', 'name': 'Agent A', 'local': true},
    {'command': 'b', 'name': 'Agent B', 'local': false},
  ];

  var toggled = 0;
  Widget app({bool visible = true, bool takesRequests = true}) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          TextButton(onPressed: () {}, child: const Text('behind')),
          Visibility(
            visible: visible,
            maintainState: true,
            child: MapSmartCard(
              column: 'agents',
              title: 'Agents',
              open: true,
              onToggle: () => toggled++,
              tr: (s) => s,
              helpers: helpers,
              takesRequests: takesRequests,
            ),
          ),
        ],
      ),
    ),
  );

  bool focusInWindow(WidgetTester tester) =>
      tester.binding.focusManager.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<OverlayWindow>() !=
      null;

  testWidgets('a hidden column hides the window, it returns with focus', (
    tester,
  ) async {
    await tester.pumpWidget(app(visible: false));
    await tester.pump();
    expect(find.byType(OverlayWindow), findsNothing);
    expect(smartWindowsShown.value, 0);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(OverlayWindow), findsOneWidget);
    expect(smartWindowsShown.value, 1);
    expect(focusInWindow(tester), isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(smartWindowsShown.value, 0);
  });

  testWidgets('Tab stays in the window', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInWindow(tester), isTrue);
    }
  });

  testWidgets('Esc still leaves when the focused button goes away', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final ask = find.byKey(const ValueKey('smart-send'));
    Focus.of(
      tester.element(
        find.descendant(of: ask, matching: find.byIcon(Icons.send)),
      ),
    ).requestFocus();
    await tester.pump();
    // The field's Ask goes away with the step; the keyboard had it.
    await tester.pumpWidget(app(takesRequests: false));
    await tester.pumpAndSettle();
    expect(ask, findsNothing);
    toggled = 0;
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(toggled, 1);
  });

  group('the central Ask AI window (no bar)', () {
    Widget central(CoreClient? client, List<String> changes) => MaterialApp(
      home: Scaffold(
        body: MapSmartCard(
          showBar: false,
          column: 'agents',
          title: 'Agents',
          open: true,
          onToggle: () {},
          onColumnChanged: changes.add,
          tr: (s) => s,
          helpers: helpers,
          client: client,
        ),
      ),
    );

    test(
      'a prompt prefix selects its category and is removed before sending',
      () {
        expect(
          smartPromptRequest('Models: Find a small model', 'agents', (s) => s),
          (column: 'models', request: 'Find a small model'),
        );
        expect(smartPromptRequest('MCP: Find a server', 'agents', (s) => s), (
          column: 'mcp',
          request: 'Find a server',
        ));
        expect(smartPromptRequest('Help me', 'agents', (s) => s), (
          column: 'agents',
          request: 'Help me',
        ));
      },
    );

    testWidgets('a late client preserves saved suggestions across edits', (
      tester,
    ) async {
      var stored = <String, dynamic>{
        'agents': [2, 'Old own one'],
        'models': ['Other model'],
      };
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'settings.update') {
          stored = Map.from((params['values'] as Map)['ask_prompts'] as Map);
        }
        return {'ask_prompts': stored};
      });
      await tester.pumpWidget(central(null, []));
      await tester.pumpWidget(central(client, []));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My new question');
      await tester.tap(find.byKey(const ValueKey('smart-save-prompt')));
      await tester.pumpAndSettle();
      expect(stored, {
        'agents': [2, 'Old own one'],
        'models': ['Other model'],
        'general': ['My new question'],
      });
      await tester.tap(find.byKey(const ValueKey('smart-all-suggestions')));
      await tester.pumpAndSettle();
      final own = find.byKey(const ValueKey('smart-own-agents-1'));
      await tester.ensureVisible(own);
      await tester.tap(own);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Old own one',
      );
      final edit = find.byKey(const ValueKey('smart-prompt-edit-agents-1'));
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('smart-prompt-edit-field')),
        'Edited',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(stored['agents'], [2, 'Edited']);
      final remove = find.descendant(
        of: own,
        matching: find.byIcon(Icons.close),
      );
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(stored['agents'], [2]);
      expect(stored['models'], ['Other model']);
    });

    testWidgets('Cancel before start acknowledgment cancels that job only', (
      tester,
    ) async {
      final pending = Completer<Map<String, dynamic>>();
      final cancelled = <Object?>[];
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'map.smart_ask') return pending.future;
        if (method == 'tasks.cancel') cancelled.add(params['task']);
        return {};
      });
      await tester.pumpWidget(central(client, []));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Which model fits my agent?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      pending.complete({'task': 'old-job'});
      await tester.pumpAndSettle();
      expect(cancelled, ['old-job']);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Which model fits my agent?',
      );
    });

    testWidgets(
      'Esc cancels a late job without interrupting a subsequent question',
      (tester) async {
        final old = Completer<Map<String, dynamic>>();
        final cancelled = <Object?>[];
        var requests = 0;
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            return ++requests == 1 ? old.future : {'task': 'second'};
          }
          if (method == 'tasks.cancel') cancelled.add(params['task']);
          return {
            'state': 'done',
            'result': {
              'status': 'answer',
              'summary': 'Second answer',
              'helper': 'a',
            },
          };
        });
        final visible = ValueNotifier(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, open, _) => MapSmartCard(
                  showBar: false,
                  column: 'agents',
                  title: 'Agents',
                  open: open,
                  onToggle: () => visible.value = !visible.value,
                  tr: (s) => s,
                  helpers: helpers,
                  client: client,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'First');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(visible.value, isFalse);
        visible.value = true;
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Second');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        old.complete({'task': 'first'});
        await tester.pumpAndSettle();
        expect(cancelled, ['first']);
        expect(find.text('Second answer'), findsOneWidget);
      },
    );

    testWidgets(
      'MCP review returns to the filled form and Apply submits once',
      (tester) async {
        final applied = Completer<Map<String, dynamic>>();
        var asks = 0, applies = 0;
        final plans = <Map<String, dynamic>>[];
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            asks++;
            return {'task': 'ask'};
          }
          if (method == 'map.smart_plan') {
            plans.add(params);
            return {
              'plan': 'checked',
              'files': [],
              'links_add': [],
              'links_remove': [],
            };
          }
          if (method == 'connections.apply') {
            applies++;
            return applied.future;
          }
          if (method == 'tasks.status') {
            return {
              'state': 'done',
              'result': {
                'helper': 'a',
                'status': 'proposal',
                'proposal': 'p',
                'agents': [
                  {'command': 'a', 'name': 'Agent A', 'mcp': true},
                ],
                'candidates': [
                  {
                    'kind': 'mcp_add',
                    'id': 'c1',
                    'title': 'Notes',
                    'agents': ['a'],
                    'needs': [
                      {'name': 'token', 'secret': true},
                    ],
                  },
                ],
              },
            };
          }
          return {};
        });
        String? initialPrompt;
        var notifications = 0;
        final open = ValueNotifier(true);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: open,
                builder: (_, visible, _) => MapSmartCard(
                  showBar: false,
                  initialPrompt: initialPrompt,
                  onApplied: (_) => notifications++,
                  column: 'agents',
                  title: 'Agents',
                  open: visible,
                  onToggle: () => open.value = !visible,
                  tr: (s) => s,
                  helpers: helpers,
                  client: client,
                ),
              ),
            ),
          ),
        );

        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Connect notes');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('smart-mcp-need-token')),
          'fixture value',
        );
        await tester.pump();
        final review = find.byKey(const ValueKey('smart-mcp-review'));
        await tester.tap(review);
        await tester.pumpAndSettle();
        expect(find.text('Configuration values stay private.'), findsOneWidget);
        open.value = false;
        await tester.pumpAndSettle();
        open.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
        await tester.pumpAndSettle();
        final secret = find.byKey(const ValueKey('smart-mcp-need-token'));
        expect(tester.widget<TextField>(secret).controller!.text, isEmpty);
        expect(tester.widget<FilledButton>(review).onPressed, isNull);
        await tester.enterText(secret, 'fixture value');
        await tester.pump();
        await tester.tap(review);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('smart-mcp-need-token')),
              )
              .controller
              ?.text,
          'fixture value',
        );
        await tester.tap(review);
        await tester.pumpAndSettle();
        final apply = find.widgetWithText(FilledButton, 'Apply');
        await tester.tap(apply);
        await tester.pump();
        expect(tester.widget<FilledButton>(apply).onPressed, isNull);
        await tester.tap(apply);
        open.value = false;
        await tester.pump();
        initialPrompt = 'Tell me about another model';
        open.value = true;
        await tester.pump();
        expect(tester.widget<FilledButton>(apply).onPressed, isNull);
        expect(find.byType(TextField), findsNothing);
        applied.complete({'ok': true});
        await tester.pumpAndSettle();
        expect(asks, 1);
        expect(applies, 1);
        expect(notifications, 1);
        expect(plans.length, 3);
        expect(plans.last['values'], {'token': 'fixture value'});
      },
    );

    testWidgets('online voice readiness and cost appear before recording', (
      tester,
    ) async {
      final home = Directory.systemTemp.createTempSync('ask-voice');
      final calls = File('${home.path}/calls');
      final voice = File('${home.path}/maprisma-voice')
        ..writeAsStringSync(
          '#!/bin/sh\necho "\$1" >> "${calls.path}"\necho \'{"enabled":true,"ready":true,"engine":"online"}\'\n',
        );
      Process.runSync('chmod', ['+x', voice.path]);
      VoiceInput.environment = {'HOME': home.path, 'PATH': home.path};
      VoiceInput.forget();
      addTearDown(() {
        VoiceInput.environment = null;
        VoiceInput.forget();
        home.deleteSync(recursive: true);
      });
      await tester.pumpWidget(central(null, []));
      for (
        var i = 0;
        i < 60 && find.byType(MicButton).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Online dictation may use API credit.'),
        findsOneWidget,
      );
      expect(find.byType(MicButton), findsOneWidget);
      expect(calls.readAsLinesSync(), everyElement('status'));
    });

    testWidgets(
      'a missing saved helper keeps the draft until a replacement is chosen',
      (tester) async {
        smartHelperChosen.value = 'unavailable-local';
        addTearDown(() => smartHelperChosen.value = null);
        final requests = <Map<String, dynamic>>[];
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            requests.add(params);
            return {'task': 'ask'};
          }
          return {
            'state': 'done',
            'result': {'status': 'answer', 'summary': 'Ready', 'helper': 'b'},
          };
        });
        await tester.pumpWidget(central(client, []));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Keep my question');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(requests, isEmpty);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('smart-send')))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('smart-helper-select')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agent B').last);
        await tester.pumpAndSettle();
        expect(find.text('Online · uses plan/tokens'), findsOneWidget);
        expect(requests, isEmpty);
        await tester.tap(find.byKey(const ValueKey('smart-send')));
        await tester.pumpAndSettle();
        expect(requests.single['command'], 'b');
        expect(requests.single['request'], 'Keep my question');
      },
    );

    testWidgets('empty and overlong drafts cannot be submitted', (
      tester,
    ) async {
      final requests = <Object?>[];
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'map.smart_ask') requests.add(params);
        return {};
      });
      await tester.pumpWidget(central(client, []));
      await tester.pumpAndSettle();
      IconButton send() =>
          tester.widget(find.byKey(const ValueKey('smart-send')));
      expect(send().onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'a' * 2000);
      await tester.pump();
      expect(send().onPressed, isNotNull);
      await tester.enterText(find.byType(TextField), 'a' * 2001);
      await tester.pump();
      expect(send().onPressed, isNull);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      expect(requests, isEmpty);
    });

    testWidgets('Back on a result goes to the main page, then to the map', (
      tester,
    ) async {
      var toggled = 0;
      final client = CoreClient(
        _FakeTransport((method, params) async {
          if (method == 'map.smart_ask') return {'task': 'ask'};
          return {
            'state': 'done',
            'result': {
              'status': 'redirect',
              'instead': {'hint': 'Nothing to change.'},
            },
          };
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapSmartCard(
              showBar: false,
              column: 'agents',
              title: 'Agents',
              open: true,
              onToggle: () => toggled++,
              tr: (s) => s,
              helpers: helpers,
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Help me');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('Nothing to change.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      expect(toggled, 0);
      expect(find.text('Nothing to change.'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'Help me',
      );
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      expect(toggled, 1);
    });

    testWidgets('Esc on a result closes Ask AI at once', (tester) async {
      var toggled = 0;
      final client = CoreClient(
        _FakeTransport((method, params) async {
          if (method == 'map.smart_ask') return {'task': 'ask'};
          return {
            'state': 'done',
            'result': {
              'status': 'redirect',
              'instead': {'hint': 'Nothing to change.'},
            },
          };
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapSmartCard(
              showBar: false,
              column: 'agents',
              title: 'Agents',
              open: true,
              onToggle: () => toggled++,
              tr: (s) => s,
              helpers: helpers,
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Help me');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('Nothing to change.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(toggled, 1);
    });

    group('Performance inside Ask AI', () {
      CoreClient performanceClient() => CoreClient(
        _FakeTransport((method, params) async {
          if (method == 'map.smart_ask') return {'task': 'ask'};
          return {
            'state': 'done',
            'result': {
              'status': 'proposal',
              'summary': '',
              'proposal': 'p1',
              'candidates': [
                {
                  'id': 'c1',
                  'kind': 'provider_config',
                  'title': 'llama.cpp',
                  'subtitle': 'Configure for this PC',
                  'reason': '',
                  'fit': 'ok',
                  'size': 0,
                  'key': 'llamacpp',
                  'profile': 'balanced',
                  'model': '*',
                  'values': {'ctx-size': 16384},
                  'reasons': {},
                  'writable': true,
                  'config_proposal': 'cfg-1',
                  'action': {'kind': 'provider_config'},
                },
              ],
            },
          };
        }),
      );

      Future<void> toProposal(
        WidgetTester tester, {
        required ValueNotifier<bool> open,
        Future<Widget> Function(
          String, {
          Map<String, dynamic>? prefill,
          required void Function(Future<bool> Function()) aside,
          required VoidCallback back,
        })?
        page,
        ValueChanged<Map<String, dynamic>>? onConfiguration,
        String Function(String)? translate,
      }) async {
        final client = performanceClient();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: open,
                builder: (_, isOpen, _) => MapSmartCard(
                  showBar: false,
                  column: 'providers',
                  title: 'Providers',
                  open: isOpen,
                  onToggle: () => open.value = !open.value,
                  tr: translate ?? (s) => s,
                  helpers: helpers,
                  client: client,
                  performancePage: page,
                  onConfiguration: onConfiguration,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Make llama faster');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
      }

      testWidgets('standalone configuration receives the exact prefill', (
        tester,
      ) async {
        final open = ValueNotifier(true);
        Map<String, dynamic>? prefill;
        await toProposal(
          tester,
          open: open,
          onConfiguration: (value) => prefill = value,
          translate: (s) =>
              s == 'Configure for this PC' ? 'PC-Konfiguration' : s,
        );
        expect(find.text('PC-Konfiguration'), findsOneWidget);
        expect(find.text('Configure for this PC'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
        await tester.pumpAndSettle();
        expect(open.value, false);
        expect(prefill?['config_proposal'], 'cfg-1');
        expect(prefill?['values'], {'ctx-size': 16384});
        expect(prefill?['model'], '*');
      });

      testWidgets(
        'Esc while it loads: the page never lands in the closed window',
        (tester) async {
          final open = ValueNotifier(true);
          final loading = Completer<Widget>();
          await toProposal(
            tester,
            open: open,
            page:
                (
                  key, {
                  Map<String, dynamic>? prefill,
                  required aside,
                  required back,
                }) => loading.future,
          );
          await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
          await tester.pump();
          expect(find.text('Checking…'), findsOneWidget);
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(open.value, isFalse);
          loading.complete(const Text('Performance page'));
          await tester.pumpAndSettle();
          open.value = true;
          await tester.pumpAndSettle();
          expect(find.text('Performance page'), findsNothing);
          expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
        },
      );

      testWidgets('a review aside comes back only when main says so', (
        tester,
      ) async {
        final open = ValueNotifier(true);
        late void Function(Future<bool> Function()) runAside;
        final reviews = <Completer<bool>>[];
        await toProposal(
          tester,
          open: open,
          page:
              (
                key, {
                Map<String, dynamic>? prefill,
                required aside,
                required back,
              }) async {
                runAside = aside;
                return const Text('Performance page');
              },
        );
        await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
        await tester.pumpAndSettle();
        expect(find.text('Performance page'), findsOneWidget);
        // The user moved on meanwhile: Ask AI stays closed.
        runAside(() {
          reviews.add(Completer<bool>());
          return reviews.last.future;
        });
        await tester.pumpAndSettle();
        expect(open.value, isFalse);
        reviews.last.complete(false);
        await tester.pumpAndSettle();
        expect(open.value, isFalse);
        // Back on the same screen: Ask AI returns on a fresh page.
        open.value = true;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
        await tester.pumpAndSettle();
        runAside(() {
          reviews.add(Completer<bool>());
          return reviews.last.future;
        });
        await tester.pumpAndSettle();
        expect(open.value, isFalse);
        reviews.last.complete(true);
        await tester.pumpAndSettle();
        expect(open.value, isTrue);
        expect(find.text('Performance page'), findsOneWidget);
      });
    });

    testWidgets('an example sends only its question after Ask', (tester) async {
      final sent = <Map<String, dynamic>>[];
      final client = CoreClient(
        _FakeTransport((method, params) async {
          if (method == 'map.smart_ask') {
            sent.add(params);
            return {'task': 'ask'};
          }
          return {
            'state': 'done',
            'result': {
              'status': 'redirect',
              'instead': {'hint': 'Nothing to change.'},
            },
          };
        }),
      );
      await tester.pumpWidget(central(client, []));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('smart-categories')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(sent.single['column'], 'auto');
      expect(sent.single['request'], 'Help my agent search my notes');
    });

    for (final share in [false, true]) {
      testWidgets('switching a follow-up to online, share context = $share', (
        tester,
      ) async {
        smartHelperChosen.value = 'a';
        addTearDown(() => smartHelperChosen.value = null);
        final requests = <Map<String, dynamic>>[];
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            requests.add(params);
            return {'task': 'ask'};
          }
          if (method == 'tasks.status') {
            return {
              'state': 'done',
              'result': {
                'helper': requests.last['command'],
                'status': 'answer',
                'summary': 'Local answer',
              },
            };
          }
          return {};
        });
        await tester.pumpWidget(central(client, []));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Local question');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('smart-helper-select')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Agent B').last);
        await tester.pumpAndSettle();
        final choice = find.widgetWithText(
          CheckboxListTile,
          'Share the previous exchange with Agent B',
        );
        expect(tester.widget<CheckboxListTile>(choice).value, false);
        if (share) {
          await tester.ensureVisible(choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
        }
        final field = find.byKey(const ValueKey('smart-follow-up'));
        await tester.ensureVisible(field);
        await tester.enterText(field, 'New question for B');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(requests.length, 2);
        expect(requests.last['command'], 'b');
        expect(
          requests.last['context'],
          share ? contains('Local answer') : isNull,
        );
      });
    }

    testWidgets(
      'Back starts a fresh question and explicit prefixes reach auto intact',
      (tester) async {
        final requests = <Map<String, dynamic>>[];
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            requests.add(params);
            return {'task': 'ask'};
          }
          return {
            'state': 'done',
            'result': {
              'status': 'answer',
              'summary': 'Previous answer',
              'helper': 'a',
            },
          };
        });
        await tester.pumpWidget(central(client, []));
        await tester.pumpAndSettle();
        Future<void> send(String text) async {
          await tester.enterText(find.byType(TextField), text);
          await tester.testTextInput.receiveAction(TextInputAction.send);
          await tester.pumpAndSettle();
        }

        await send('First question');
        await send('Tell me more');
        expect(requests.last['context'], contains('First question'));
        await tester.tap(find.text('Back').first);
        await tester.pumpAndSettle();
        await send('MCP: find notes');
        expect(requests.last['column'], 'auto');
        expect(requests.last['request'], 'MCP: find notes');
        expect(requests.last.containsKey('context'), isFalse);
      },
    );

    testWidgets(
      'a clarification and follow-up retain the question and checked answer',
      (tester) async {
        final requests = <Map<String, dynamic>>[];
        final client = CoreClient.fromCall((method, params) async {
          if (method == 'map.smart_ask') {
            requests.add(params);
            return {'task': 'ask'};
          }
          if (method == 'tasks.status') {
            return {
              'state': 'done',
              'result': {
                'helper': 'a',
                if (requests.length == 1) ...{
                  'status': 'clarify',
                  'question': 'Which agent?',
                  'choices': [],
                } else ...{
                  'status': 'answer',
                  'summary': 'The installed model fits.',
                },
              },
            };
          }
          return {};
        });
        await tester.pumpWidget(central(client, []));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'What fits?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('smart-follow-up')),
          'My local agent',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(requests.last['answer'], 'My local agent');
        expect(requests.last['context'], contains('Which agent?'));
        await tester.enterText(
          find.byKey(const ValueKey('smart-follow-up')),
          'Why that one?',
        );
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(requests.last['request'], 'Why that one?');
        expect(requests.last['context'], contains('The installed model fits.'));
        await tester.tap(find.text('New question'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
      },
    );
  });
}

class _FakeTransport implements ServiceTransport {
  _FakeTransport(this.onCall);
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )
  onCall;

  @override
  bool get isConnected => true;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => onCall(method, params);

  @override
  void dispose() {}

  @override
  Future<void> shutdown() async {}
}
