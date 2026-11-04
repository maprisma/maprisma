import 'dart:convert';
import 'dart:io';
import 'package:maprisma/agent_map.dart';
import 'package:maprisma/map_groups.dart';
import 'package:maprisma/map_welcome.dart';
import 'package:maprisma/map_addons_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const columns = ['MCP servers and skills', 'Agents', 'Providers', 'Models'];
Map<String, dynamic> adapter(
  String id, {
  bool enabled = false,
  bool verified = true,
}) => {
  'id': id,
  'name': id,
  'version': '1.0',
  'summary': 'Summary',
  'kind': 'agent',
  'enabled': enabled,
  'supported': true,
  'verified': verified,
  'state': verified ? 'verified' : 'refused',
};
Widget focus({
  bool welcome = false,
  bool detecting = false,
  Map<String, List<String>> locked = const {},
  VoidCallback? showTerminal,
  List<Map<String, dynamic>> items = const [],
  List<Map<String, dynamic>> nodes = const [],
  Set<String> detected = const {},
  Future<void> Function(List<String>)? apply,
  Future<void> Function(String, bool)? toggle,
  VoidCallback? online,
  VoidCallback? back,
}) => MaterialApp(
  home: Scaffold(
    body: MapAddonsFocus(
      category: 1,
      items: items,
      nodes: nodes,
      detected: detected,
      entries: null,
      busy: false,
      locked: locked,
      onShowTerminal: showTerminal,
      online: true,
      tr: (k) => k,
      welcome: welcome,
      detecting: detecting,
      onApply: apply,
      onLater: () {},
      onDetect: () {},
      onBack: back ?? () {},
      onToggle: toggle ?? (_, _) async {},
      onCatalog: online ?? () {},
      onOnline: (_) {},
      onInstall: (_) {},
      onMenu: (_, _) {},
      onNode: (_) {},
      onModels: () {},
      onConnections: () {},
      onFolders: () {},
    ),
  ),
);
void main() {
  test('group metadata never enters graph counts or AI-help facts', () {
    final graph = <String, dynamic>{'nodes': <dynamic>[], 'edges': <dynamic>[]};
    final before = jsonEncode(graph);
    final groups = MapGroup.fromGraph(graph, columns);
    expect(groups.length, 4);
    expect(groups.every((g) => g.dummy), isTrue);
    expect(jsonEncode(graph), before);
    graph['nodes'].add({'column': 1});
    expect(MapGroup.fromGraph(graph, columns).map((g) => g.dummy), [
      true,
      false,
      true,
      true,
    ]);
    graph['nodes'].clear();
    expect(MapGroup.fromGraph(graph, columns).every((g) => g.dummy), isTrue);
  });
  testWidgets(
    'dummies have no drop targets; focus collapse preserves pan and zoom',
    (tester) async {
      final graph = <String, dynamic>{
        'nodes': <dynamic>[],
        'edges': <dynamic>[],
      };
      final controller = TransformationController()
        ..value = Matrix4.identity()
        ..value.translateByDouble(12, 34, 0, 1);
      addTearDown(controller.dispose);
      final before = controller.value.clone();
      int? expanded;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => expanded == null
                  ? AgentMap(
                      graph: graph,
                      tr: (k) => k,
                      onAgent: (_) {},
                      controller: controller,
                      groups: MapGroup.fromGraph(graph, columns),
                      onExpandGroup: (i) => setState(() => expanded = i),
                    )
                  : MapFocus(
                      title: columns[expanded!],
                      tr: (k) => k,
                      onBack: () => setState(() => expanded = null),
                      child: const Text('focused'),
                    ),
            ),
          ),
        ),
      );
      expect(find.byType(MapGroupCard), findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byType(MapGroupCard),
          matching: find.byWidgetPredicate((w) => w is DragTarget),
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Expand').at(1));
      await tester.pumpAndSettle();
      expect(find.text('focused'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MapGroupCard), findsNWidgets(4));
      expect(controller.value, before);
      await tester.tap(find.byTooltip('Expand').at(1));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.byType(MapGroupCard), findsNWidgets(4));
    },
  );
  testWidgets(
    'catalog only loads on explicit request and dummy has no On or Off sections',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(focus(online: () => requests++));
      await tester.pumpAndSettle();
      expect(requests, 0);
      expect(find.text('On'), findsNothing);
      expect(find.text('Off'), findsNothing);
      await tester.ensureVisible(
        find.widgetWithText(TextButton, 'Look for add-ons online'),
      );
      await tester.tap(
        find.widgetWithText(TextButton, 'Look for add-ons online'),
      );
      expect(requests, 1);
    },
  );
  testWidgets('welcome footer is fixed and detection gates Switch on', (
    tester,
  ) async {
    List<String>? applied;
    final items = [
      adapter('first'),
      adapter('bad', verified: false),
      for (var i = 0; i < 30; i++) adapter('item-$i'),
    ];
    await tester.pumpWidget(
      focus(
        welcome: true,
        detecting: true,
        items: items,
        detected: {'first'},
        apply: (ids) async => applied = ids,
      ),
    );
    expect(find.text('Later').hitTestable(), findsOneWidget);
    expect(find.text('Switch on').hitTestable(), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Switch on'))
          .onPressed,
      isNull,
    );
    await tester.pumpWidget(
      focus(
        welcome: true,
        items: items,
        detected: {'first'},
        apply: (ids) async => applied = ids,
      ),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Switch on'));
    await tester.pumpAndSettle();
    expect(applied, ['first']);
  });
  testWidgets('late detection preserves a manual exclusion', (tester) async {
    List<String>? applied;
    final items = [adapter('first')];
    await tester.pumpWidget(
      focus(welcome: true, items: items, apply: (ids) async => applied = ids),
    );
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      focus(
        welcome: true,
        items: items,
        detected: {'first'},
        apply: (ids) async => applied = ids,
      ),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Switch on'));
    await tester.pumpAndSettle();
    expect(applied, isEmpty);
  });
  testWidgets(
    'normal switching acts immediately and is guarded while its agent runs',
    (tester) async {
      final calls = <bool>[];
      final item = adapter('first', enabled: true);
      await tester.pumpWidget(
        focus(
          items: [item],
          nodes: [
            {'label': 'Node', 'detail': ''},
          ],
          toggle: (_, on) async => calls.add(on),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch off'));
      await tester.pumpAndSettle();
      expect(calls, [false]);
      await tester.pumpWidget(
        focus(
          items: [item],
          locked: const {
            'first': ['Claude Code'],
          },
          nodes: [
            {'label': 'Node', 'detail': ''},
          ],
          toggle: (_, on) async => calls.add(on),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      final menu = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Switch off'),
      );
      expect(menu.enabled, isFalse);
      expect(calls, [false]);
    },
  );
  test('the lock text names the running agents', () {
    String tr(String k) => k;
    expect(
      addonsLockedText(tr, const ['Claude Code']),
      'Claude Code is running in a terminal. Its add-on can be switched off, updated or removed when it has finished.',
    );
    expect(
      addonsLockedText(tr, const ['Claude Code', 'Pi']),
      'Claude Code, Pi are running in terminals. Their add-ons can be switched off, updated or removed when they have finished.',
    );
  });
  test('every text of the add-ons page is in the app\'s translations', () {
    // The app reads assets/translations, which tools/flutter-assets.py fills
    // only with its KEYS: a text missing there shows in English.
    final source = File('lib/map_addons_focus.dart').readAsStringSync();
    final texts = {
      for (final m in RegExp(r"tr\(\s*'((?:[^'\\]|\\.)*)'").allMatches(source))
        m.group(1)!.replaceAll(r"\'", "'"),
      'Show terminal',
    };
    expect(texts, contains('Show terminal'));
    expect(
      texts,
      contains(
        '{0} is running in a terminal. Its add-on can be switched off, updated or removed when it has finished.',
      ),
    );
    for (final code in ['de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
      final strings =
          jsonDecode(File('assets/translations/$code.json').readAsStringSync())
              as Map<String, dynamic>;
      expect(
        texts.where((t) => !strings.containsKey(t)),
        isEmpty,
        reason: 'missing in $code',
      );
    }
  });
  testWidgets(
    'a running agent: the banner names it, shows its terminal, and only its add-on is locked',
    (tester) async {
      var shown = 0;
      final calls = <bool>[];
      const reason =
          'Claude Code is running in a terminal. Its add-on can be switched off, updated or removed when it has finished.';
      await tester.pumpWidget(
        focus(
          items: [
            adapter('first', enabled: true),
            adapter('second', enabled: true),
          ],
          locked: const {
            'first': ['Claude Code'],
          },
          showTerminal: () => shown++,
          nodes: [
            {'label': 'Node', 'detail': ''},
          ],
          toggle: (_, on) async => calls.add(on),
        ),
      );
      final banner = find.byKey(const ValueKey('addons-locked'));
      expect(banner, findsOneWidget);
      expect(
        find.descendant(of: banner, matching: find.text(reason)),
        findsOneWidget,
      );
      // The old general line is replaced, not shown twice.
      expect(
        find.text('Finish running agents before changing add-ons.'),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('addons-locked-show')));
      await tester.pumpAndSettle();
      expect(shown, 1);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      final item = find.widgetWithText(PopupMenuItem<String>, 'Switch off');
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      expect(
        find.descendant(of: item, matching: find.text(reason)),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      // Another agent's add-on is not held: it switches off at once.
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>).at(1));
      await tester.pumpAndSettle();
      final other = find.widgetWithText(PopupMenuItem<String>, 'Switch off');
      expect(tester.widget<PopupMenuItem<String>>(other).enabled, isTrue);
      expect(
        find.descendant(of: other, matching: find.text(reason)),
        findsNothing,
      );
      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(calls, [false]);
    },
  );
  testWidgets(
    'switching on is never locked, and there is no banner without a held add-on',
    (tester) async {
      final calls = <bool>[];
      await tester.pumpWidget(
        focus(
          items: [adapter('first')],
          locked: const {
            'first': ['Claude Code'],
          },
          nodes: [
            {'label': 'Node', 'detail': ''},
          ],
          toggle: (_, on) async => calls.add(on),
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      final item = find.widgetWithText(PopupMenuItem<String>, 'Switch on');
      expect(tester.widget<PopupMenuItem<String>>(item).enabled, isTrue);
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(calls, [true]);
      // Agents run, but none holds an add-on of this page: no banner.
      await tester.pumpWidget(
        focus(
          items: [adapter('second', enabled: true)],
          locked: const {
            'first': ['Claude Code'],
          },
        ),
      );
      expect(find.byKey(const ValueKey('addons-locked')), findsNothing);
    },
  );
  testWidgets('without running agents there is no banner and no reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      focus(
        items: [adapter('first', enabled: true)],
        nodes: [
          {'label': 'Node', 'detail': ''},
        ],
      ),
    );
    expect(find.byKey(const ValueKey('addons-locked')), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('can be switched off, updated'), findsNothing);
  });
  testWidgets('a held welcome checkbox cannot be unticked and says why', (
    tester,
  ) async {
    const reason =
        'Pi is running in a terminal. Its add-on can be switched off, updated or removed when it has finished.';
    await tester.pumpWidget(
      focus(
        welcome: true,
        locked: const {
          'first': ['Pi'],
        },
        items: [adapter('first'), adapter('second')],
        detected: {'first', 'second'},
      ),
    );
    final boxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(boxes.at(0)).onChanged, isNull);
    expect(tester.widget<Checkbox>(boxes.at(1)).onChanged, isNotNull);
    expect(
      find.ancestor(
        of: find.byType(Checkbox),
        matching: find.byWidgetPredicate(
          (w) => w is Tooltip && w.message == reason,
        ),
      ),
      findsOneWidget,
    );
    // Switch on keeps the held add-on ticked, so it is not locked.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Switch on'))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets(
    'Welcome Agents reopens its first-use focus with the fixed footer',
    (tester) async {
      bool expanded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  MapWelcome(
                    tr: (k) => k,
                    busy: false,
                    skipSearch: false,
                    searched: false,
                    onLook: () {},
                    onSkip: () {},
                    onAgents: () => setState(() => expanded = true),
                  ),
                  Expanded(
                    child: expanded
                        ? MapAddonsFocus(
                            category: 1,
                            items: const [],
                            detected: const {},
                            nodes: const [],
                            entries: null,
                            busy: false,
                            online: true,
                            tr: (k) => k,
                            welcome: true,
                            onBack: () => setState(() => expanded = false),
                            onToggle: (_, _) async {},
                            onCatalog: () {},
                            onOnline: (_) {},
                            onInstall: (_) {},
                            onMenu: (_, _) {},
                            onNode: (_) {},
                            onModels: () {},
                            onConnections: () {},
                            onFolders: () {},
                            onApply: (_) async {},
                            onLater: () {},
                          )
                        : const Text('other map'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Agents'));
      await tester.pumpAndSettle();
      expect(find.text('Switch on').hitTestable(), findsOneWidget);
      expect(find.text('Later').hitTestable(), findsOneWidget);
    },
  );
}
