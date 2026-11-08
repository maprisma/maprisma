import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/backend.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/overlay_window.dart';

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

    testWidgets('own suggestions: save, edit, Esc, remove, built-in again', (
      tester,
    ) async {
      final saved = <Object?>[];
      Object? stored = {
        'agents': [2, 'Old own one'],
      };
      final client = CoreClient.fromCall((method, params) async {
        if (method == 'settings.get') return {'ask_prompts': stored};
        if (method == 'settings.update') {
          stored = (params['values'] as Map)['ask_prompts'];
          saved.add(stored);
          return {'ask_prompts': stored};
        }
        return {};
      });
      await tester.pumpWidget(central(client, []));
      await tester.pumpAndSettle();
      // Loaded: one built-in kept, one own; the others of the category gone.
      expect(find.byKey(const ValueKey('smart-example-2')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-example-3')), findsNothing);
      expect(find.byKey(const ValueKey('smart-own-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-prompts-reset')), findsOneWidget);
      // Save what is typed, its category prefix left out, spaces collapsed.
      await tester.enterText(
        find.byType(TextField),
        'Agents:   Which   agents run now?',
      );
      await tester.tap(find.byKey(const ValueKey('smart-save-prompt')));
      await tester.pumpAndSettle();
      expect(saved.last, {
        'agents': [2, 'Old own one', 'Which agents run now?'],
      });
      await tester.tap(find.byKey(const ValueKey('smart-save-prompt')));
      await tester.pumpAndSettle();
      expect(find.text('That is already a suggestion.'), findsOneWidget);
      expect(saved, hasLength(1));
      // Edit the built-in one: Esc ends the edit only, Enter keeps it.
      await tester.tap(find.byKey(const ValueKey('smart-prompt-edit-0')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('smart-prompt-edit-field'));
      await tester.enterText(field, 'Changed');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(OverlayWindow), findsOneWidget);
      expect(field, findsNothing);
      expect(saved, hasLength(1));
      await tester.tap(find.byKey(const ValueKey('smart-prompt-edit-0')));
      await tester.pumpAndSettle();
      await tester.enterText(field, '  Which agents  need sign-in now? ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(saved.last, {
        'agents': [
          'Which agents need sign-in now?',
          'Old own one',
          'Which agents run now?',
        ],
      });
      // An own one fills the question with the category in front.
      await tester.ensureVisible(find.byKey(const ValueKey('smart-own-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-own-1')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'Agents: Old own one',
      );
      // × removes; ↺ brings back the built-in ones (the column is dropped).
      final remove = find.descendant(
        of: find.byKey(const ValueKey('smart-own-1')),
        matching: find.byIcon(Icons.close),
      );
      await tester.ensureVisible(remove);
      await tester.pumpAndSettle();
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(saved.last, {
        'agents': ['Which agents need sign-in now?', 'Which agents run now?'],
      });
      await tester.ensureVisible(
        find.byKey(const ValueKey('smart-prompts-reset')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-prompts-reset')));
      await tester.pumpAndSettle();
      expect(saved.last, <String, Object>{});
      for (final index in smartBuiltinPrompts('agents')) {
        expect(find.byKey(ValueKey('smart-example-$index')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('smart-prompts-reset')), findsNothing);
    });

    testWidgets('an example fills the prompt and keeps the same window', (
      tester,
    ) async {
      final changes = <String>[];
      await tester.pumpWidget(central(null, changes));
      await tester.pumpAndSettle();
      final window = tester.state(find.byType(OverlayWindow));
      expect(
        find.byKey(const ValueKey('smart-prompt-examples')),
        findsOneWidget,
      );
      // The category row first, then the chosen category's prompt helps.
      expect(
        find.byKey(const ValueKey('smart-category-models')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('smart-category-mcp')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('smart-category-card-mcp')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('smart-example-2')), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      expect(find.text('Ask AI · MCP servers and skills'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'MCP servers and skills: Find an MCP server for my notes',
      );
      expect(tester.state(find.byType(OverlayWindow)), same(window));
      expect(find.byKey(const ValueKey('smart-card')), findsOneWidget);
      expect(changes, ['mcp']);
    });

    testWidgets(
      'a category shows its presets; a started one waits for the name',
      (tester) async {
        await tester.pumpWidget(central(null, []));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('smart-category-agents')));
        await tester.pumpAndSettle();
        expect(find.text('Update an agent…'), findsOneWidget);
        expect(find.text('Download a model…'), findsNothing);
        // The presets line scrolls sideways when it is too long.
        await tester.ensureVisible(find.text('Update an agent…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Update an agent…'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Agents: Update the agent ',
        );
        await tester.tap(find.byKey(const ValueKey('smart-category-models')));
        await tester.pumpAndSettle();
        expect(find.text('Download a model…'), findsOneWidget);
        expect(find.text('Update an agent…'), findsNothing);
      },
    );

    testWidgets('a presets line too long for the window gets arrows', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(700, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(central(null, []));
      await tester.pumpAndSettle();
      final left = find.byKey(const ValueKey('smart-presets-left'));
      final right = find.byKey(const ValueKey('smart-presets-right'));
      expect(left, findsNothing);
      expect(right, findsOneWidget);
      await tester.ensureVisible(right);
      await tester.pumpAndSettle();
      await tester.tap(right);
      await tester.pumpAndSettle();
      expect(left, findsOneWidget);
      // Back to the start: the left arrow goes; the right one is there again.
      for (var i = 0; i < 5 && left.evaluate().isNotEmpty; i++) {
        await tester.tap(left);
        await tester.pumpAndSettle();
      }
      expect(left, findsNothing);
      expect(right, findsOneWidget);
      expect(tester.takeException(), isNull);
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
                  'kind': 'provider_action',
                  'title': 'llama.cpp',
                  'subtitle': 'Performance',
                  'reason': '',
                  'fit': 'ok',
                  'size': 0,
                  'key': 'llamacpp',
                  'step': 'performance',
                  'action': {'kind': 'provider_action'},
                },
              ],
            },
          };
        }),
      );

      Future<void> toProposal(
        WidgetTester tester, {
        required ValueNotifier<bool> open,
        required Future<Widget> Function(
          String, {
          required void Function(Future<bool> Function()) aside,
          required VoidCallback back,
        })
        page,
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
                  tr: (s) => s,
                  helpers: helpers,
                  client: client,
                  performancePage: page,
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

      testWidgets(
        'Esc while it loads: the page never lands in the closed window',
        (tester) async {
          final open = ValueNotifier(true);
          final loading = Completer<Widget>();
          await toProposal(
            tester,
            open: open,
            page: (key, {required aside, required back}) => loading.future,
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
          page: (key, {required aside, required back}) async {
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
      await tester.tap(find.byKey(const ValueKey('smart-category-mcp')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-example-0')));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(sent.single['column'], 'mcp');
      expect(sent.single['request'], 'Find an MCP server for my notes');
    });

    testWidgets(
      'Move to switches the category in place and keeps the question',
      (tester) async {
        final calls = <String>[];
        final client = CoreClient(
          _FakeTransport((method, params) async {
            calls.add(method);
            if (method == 'map.smart_ask') return {'task': 'ask'};
            return {
              'state': 'done',
              'result': {
                'helper': 'Agent B',
                'local': false,
                'status': 'redirect',
                'instead': {
                  'hint': 'Models are managed in the Models column.',
                  'column': 'models',
                  'request': '',
                },
              },
            };
          }),
        );
        final changes = <String>[];
        await tester.pumpWidget(central(client, changes));
        await tester.pumpAndSettle();
        final window = tester.state(find.byType(OverlayWindow));
        await tester.enterText(find.byType(TextField), 'install qwencoder');
        await tester.tap(find.byKey(const ValueKey('smart-send')));
        await tester.pumpAndSettle();
        expect(find.text('Move to Models'), findsOneWidget);
        calls.clear();
        await tester.tap(find.text('Move to Models'));
        await tester.pumpAndSettle();
        expect(find.text('Ask AI · Models'), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'Models: install qwencoder',
        );
        expect(changes.last, 'models');
        expect(calls, isEmpty); // nothing is asked again by itself
        expect(tester.state(find.byType(OverlayWindow)), same(window));
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
