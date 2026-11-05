import 'dart:convert';
import 'dart:io';

import 'package:maprisma/map_layout.dart' show withAgentLinks;
import 'package:maprisma/agent_action_dialog.dart';
import 'package:maprisma/agent_map.dart';
import 'package:maprisma/agent_usage.dart';
import 'package:maprisma/backend.dart';
import 'package:maprisma/connections_view.dart' show ConnectionReview;
import 'package:maprisma/map_editor.dart';
import 'package:maprisma/map_zoom.dart';
import 'package:maprisma/map_groups.dart';
import 'package:maprisma/map_legend.dart';
import 'package:maprisma/map_lights.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/task_card.dart' show TaskReview;
import 'package:maprisma/window_popup.dart' show popupSize;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'map_layout_test.dart' show fixtureGraph;

class _FakeSmartTransport implements ServiceTransport {
  _FakeSmartTransport(this.onCall);
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

Future<void> mount(
  WidgetTester tester, {
  required List<Map<String, dynamic>> edits,
  Map<String, dynamic>? graph,
  Map<String, dynamic>? saved,
  ValueChanged<Map<String, dynamic>>? onLayout,
  bool active = false,
  bool reduced = false,
  String mode = 'all',
  Set<String>? selection,
  bool smartCards = false,
  List<Map<String, dynamic>> smartHelpers = const [
    {'command': 'local-helper', 'name': 'Local helper', 'local': true},
  ],
  SmartStatusData? smartStatus,
  (int, String)? smartStatusTarget,
  CoreClient? client,
  ValueChanged<Map<String, dynamic>>? onSmartApplied,
  TransformationController? controller,
  Size size = const Size(1500, 1000),
  void Function(String kind, String target)? onAdd,
  void Function(BuildContext, String, Map<String, dynamic>)? onMissing,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final g = graph ?? fixtureGraph(active: active);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: reduced),
        child: Scaffold(
          body: MapEditor(
            graph: g,
            saved: saved ?? {},
            onLayout: onLayout,
            onEdit: (e) async {
              edits.add(e);
            },
            onMissing: onMissing,
            tr: (s) => s,
            animate: mode,
            selection: selection,
            smartCards: smartCards,
            smartHelpers: smartHelpers,
            smartStatus: smartStatus,
            smartStatusTarget: smartStatusTarget,
            client: client,
            onSmartApplied: onSmartApplied,
            controller: controller,
            onAdd: onAdd,
            groups: smartCards
                ? MapGroup.fromGraph(g, const [
                    'MCP servers and skills',
                    'Agents',
                    'Providers',
                    'Models',
                  ])
                : null,
          ),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => smartHelperChosen.value = null);
  testWidgets('connecting a server: Review sends its agent', (tester) async {
    final calls = <String, Map<String, dynamic>>{};
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        calls[method] = params;
        if (method == 'map.smart_ask') return {'task': 'ask'};
        if (method == 'map.smart_plan') {
          return {
            'plan': 'plan-1',
            'files': const [],
            'links_add': const [],
            'links_remove': const [],
          };
        }
        return {
          'state': 'done',
          'result': {
            'status': 'proposal',
            'proposal': 'p',
            'candidates': [
              {
                'id': 'c1',
                'kind': 'mcp_connect',
                'agents': ['codex'],
                'title': 'pdfcraft',
                'subtitle': 'Codex',
                'fit': 'ok',
                'size': 0,
              },
            ],
          },
        };
      }),
    );
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'mcp',
            title: 'MCP',
            open: true,
            enabled: true,
            onToggle: () {},
            tr: (s) => s,
            client: client,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'connect pdfcraft to codex');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
    await tester.pump();
    await tester.pump();
    expect(calls['map.smart_plan']?['agents'], ['codex']);
    expect(find.byType(ConnectionReview), findsOneWidget);
  });

  testWidgets('after a web answer the button hands the prompt to the app', (
    tester,
  ) async {
    final plans = <Map<String, dynamic>>[];
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        if (method == 'map.smart_ask') return {'task': 'ask'};
        if (method == 'map.smart_review') {
          return {'preview': 'x', 'name': 'Claude Code', 'prompt': 'do it'};
        }
        return {
          'state': 'done',
          'result': {
            'status': 'redirect',
            'instead': {'hint': 'Download it.', 'column': null},
            'helper': 'claude',
            'proposal': 'p',
            'candidates': [
              {'id': 'task', 'kind': 'agent_task', 'title': 'claude'},
            ],
          },
        };
      }),
    );
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'mcp',
            title: 'MCP',
            open: true,
            enabled: true,
            onToggle: () {},
            tr: (s) => s,
            client: client,
            onTask: plans.add,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'update craft');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Do it with Claude Code…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('smart-do-it')));
    await tester.pump();
    await tester.pump();
    expect(plans.single['prompt'], 'do it');
  });

  testWidgets('a provider step opens the app page for it', (tester) async {
    final chosen = <String>[];
    var closed = false;
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        if (method == 'map.smart_ask') return {'task': 'ask'};
        return {
          'state': 'done',
          'result': {
            'status': 'proposal',
            'proposal': 'p',
            'candidates': [
              {
                'id': 'c1',
                'kind': 'provider_action',
                'title': 'Ollama',
                'subtitle': 'install',
                'fit': 'ok',
                'size': 0,
                'key': 'ollama',
                'step': 'install',
              },
            ],
          },
        };
      }),
    );
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'providers',
            title: 'Providers',
            open: true,
            enabled: true,
            onToggle: () => closed = true,
            tr: (s) => s,
            client: client,
            onProvider: (step, key, name) => chosen.add('$step $key $name'),
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'install ollama');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
    await tester.pump();
    expect(chosen, ['install ollama Ollama']);
    expect(closed, isTrue);
  });

  testWidgets('an agent action: normal review, then the terminal result', (
    tester,
  ) async {
    final applied = <Map<String, dynamic>>[];
    var closed = false;
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        if (method == 'map.smart_ask') return {'task': 'ask'};
        if (method == 'map.smart_review') {
          return {
            'preview': 'p1',
            'runnable': true,
            'action': 'update',
            'name': 'Codex',
            'commands': const ['codex update'],
            'data': const [],
            'note': '',
            'url': '',
          };
        }
        if (method == 'map.smart_run') {
          return {'session': 's1', 'command': 'codex', 'path': '/x'};
        }
        return {
          'state': 'done',
          'result': {
            'status': 'proposal',
            'proposal': 'p',
            'candidates': [
              {
                'id': 'c1',
                'kind': 'agent_action',
                'title': 'Codex',
                'subtitle': 'update',
                'fit': 'ok',
                'size': 0,
              },
            ],
          },
        };
      }),
    );
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'agents',
            title: 'Agents',
            open: true,
            enabled: true,
            onToggle: () => closed = true,
            tr: (s) => s,
            client: client,
            onApplied: applied.add,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'update codex');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
    await tester.pump();
    await tester.pump();
    final review = tester.widget<AgentActionReview>(
      find.byType(AgentActionReview),
    );
    review.onConfirm();
    await tester.pump();
    await tester.pump();
    expect(applied.single['session'], 's1');
    expect(closed, isTrue);
  });

  testWidgets('a folder move: preview task, review, run, then closed', (
    tester,
  ) async {
    final calls = <String>[];
    final applied = <Map<String, dynamic>>[];
    var closed = false;
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        calls.add(method);
        if (method == 'map.smart_ask') return {'task': 'ask'};
        if (method == 'map.smart_review') return {'task': 'plan'};
        if (method == 'map.smart_run') return {'task': 'run'};
        return switch (params['task']) {
          'ask' => {
            'state': 'done',
            'result': {
              'status': 'proposal',
              'proposal': 'p',
              'candidates': [
                {
                  'id': 'c1',
                  'kind': 'model_move',
                  'title': 'Models',
                  'subtitle': '→ Data',
                  'fit': 'ok',
                  'size': 0,
                },
              ],
            },
          },
          'plan' => {
            'state': 'done',
            'result': {
              'notes': ['Moves 2 GB'],
              'files': const [],
            },
          },
          _ => {
            'state': 'done',
            'result': {'ok': true, 'move_undo': 'u'},
          },
        };
      }),
    );
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'models',
            title: 'Models',
            open: true,
            enabled: true,
            onToggle: () => closed = true,
            tr: (s) => s,
            client: client,
            onApplied: applied.add,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'move my models to Data');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Moves 2 GB'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('smart-move-confirm')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(calls, contains('map.smart_run'));
    expect(applied.single['move_undo'], 'u');
    expect(closed, isTrue);
  });

  testWidgets('the legend explains the marks', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MapLegendButton(tr: (s) => s)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('map-legend')));
    await tester.pumpAndSettle();
    expect(find.text('What the marks mean'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-battery')), findsNWidgets(4));
    // The defaults: yellow from 75 % used, red from 90 % (a tenth left is red).
    expect(find.text('Yellow: 25 % or less is left.'), findsOneWidget);
    expect(find.text('Red: 10 % or less is left.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets("the legend's levels are those of Settings › Costs", (
    tester,
  ) async {
    expect(warnPercents({'warn_yellow': 60, 'warn_red': 95}), (60, 95));
    expect(warnPercents({'warn_yellow': 90, 'warn_red': 80}), (75, 90));
    expect(warnPercents(const {}), (75, 90));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapLegendButton(
            tr: (s) => s,
            levels: warnPercents({'warn_yellow': 60, 'warn_red': 95}),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('map-legend')));
    await tester.pumpAndSettle();
    expect(find.text('Yellow: 40 % or less is left.'), findsOneWidget);
    expect(find.text('Red: 5 % or less is left.'), findsOneWidget);
    expect(find.byKey(const ValueKey('agent-battery-stale')), findsOneWidget);
  });

  testWidgets('MCP: proposal, agents and fields, then the normal review', (
    tester,
  ) async {
    final calls = <String, Map<String, dynamic>>{};
    final client = CoreClient(
      _FakeSmartTransport((method, params) async {
        calls[method] = params;
        return switch (method) {
          'map.smart_ask' => {'task': 't'},
          'tasks.status' => {
            'state': 'done',
            'result': {
              'status': 'proposal',
              'summary': 'One fits',
              'proposal': 'p',
              'agents': [
                {'command': 'claude', 'name': 'Claude Code'},
                {'command': 'codex', 'name': 'Codex'},
              ],
              'candidates': [
                {
                  'id': 'c1',
                  'kind': 'mcp_add',
                  'title': 'GitHub',
                  'subtitle': 'io.github/gh',
                  'reason': 'official',
                  'fit': 'ok',
                  'size': 0,
                  'agents': ['claude'],
                  'needs': [
                    {
                      'name': 'TOKEN',
                      'description': 'A token',
                      'secret': true,
                      'value': '',
                      'hint': '',
                    },
                  ],
                },
              ],
            },
          },
          'map.smart_plan' => {
            'plan': 'plan-1',
            'files': const [],
            'links_add': const [],
            'links_remove': const [],
          },
          _ => const <String, dynamic>{},
        };
      }),
    );
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'mcp',
            title: 'MCP servers and skills',
            open: true,
            enabled: true,
            onToggle: () {},
            tr: (s) => s,
            client: client,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'a github server');
    await tester.tap(find.byKey(const ValueKey('smart-send')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
    await tester.pump();
    final review = find.byKey(const ValueKey('smart-mcp-review'));
    expect(tester.widget<FilledButton>(review).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('smart-mcp-need-TOKEN')),
      's3cret',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('smart-mcp-agent-codex')),
    );
    await tester.tap(find.byKey(const ValueKey('smart-mcp-agent-codex')));
    await tester.pump();
    await tester.ensureVisible(review);
    await tester.pump();
    expect(tester.widget<FilledButton>(review).onPressed, isNotNull);
    await tester.tap(review);
    await tester.pump();
    await tester.pump();
    expect(calls['map.smart_plan'], {
      'proposal': 'p',
      'candidate': 'c1',
      'agents': ['claude', 'codex'],
      'values': {'TOKEN': 's3cret'},
    });
    expect(find.byType(ConnectionReview), findsOneWidget);
  });

  testWidgets('a column without a helper yet says so before anyone types', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            column: 'agents',
            takesRequests: false,
            title: 'Agents',
            open: true,
            enabled: true,
            onToggle: () {},
            tr: (s) => s,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text('This column does not take requests yet.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'drawing from a box emits one reviewed edit, invalid drop does nothing',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      await tester.dragFrom(
        tester.getCenter(find.text('agent:a')),
        const Offset(302, 0),
      );
      await tester.pump();
      expect(edits.single['source'], 'agent:a');
      expect(edits.single['target'], 'runtime:r');
      edits.clear();
      await tester.dragFrom(
        tester.getCenter(find.text('agent:a')),
        const Offset(0, 146),
      );
      await tester.pump();
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('a refused drop says why in a short note', (tester) async {
    final edits = <Map<String, dynamic>>[];
    await mount(tester, edits: edits);
    // agent:b has no line to runtime:r, which serves model:r:n.
    await tester.dragFrom(
      tester.getCenter(find.text('agent:b')),
      tester.getCenter(find.text('model:r:n')) -
          tester.getCenter(find.text('agent:b')),
    );
    await tester.pump();
    expect(edits, isEmpty);
    expect(
      find.text('Connect agent:b to runtime:r first, then choose this model.'),
      findsOneWidget,
    );
    // Two agents cannot be joined by a line.
    await tester.dragFrom(
      tester.getCenter(find.text('agent:a')),
      tester.getCenter(find.text('agent:b')) -
          tester.getCenter(find.text('agent:a')),
    );
    await tester.pump();
    expect(edits, isEmpty);
    expect(find.text('These two boxes cannot be connected.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('a missing model does not ask for an existing provider link', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[];
    final graph = fixtureGraph();
    final model = (graph['nodes'] as List)
        .cast<Map<String, dynamic>>()
        .where((node) => node['id'] == 'model:r:m')
        .single;
    model['status'] = 'missing';
    await mount(tester, edits: edits, graph: graph);
    await tester.dragFrom(
      tester.getCenter(find.text('agent:a')),
      tester.getCenter(find.text('model:r:m')) -
          tester.getCenter(find.text('agent:a')),
    );
    await tester.pump();
    expect(edits, isEmpty);
    expect(find.text('This model is no longer on this PC.'), findsOneWidget);
    expect(
      find.text('Connect agent:a to runtime:r first, then choose this model.'),
      findsNothing,
    );
  });
  testWidgets('an online provider not its own says why (review 063 F1)', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[];
    final graph = fixtureGraph();
    final nodes = [
      for (final n in graph['nodes'] as List) Map<String, dynamic>.from(n),
    ];
    graph['nodes'] = nodes;
    nodes.firstWhere((n) => n['id'] == 'agent:a')
      ..['own_provider'] = 'cloud:openai'
      ..['own_login'] = true;
    nodes.firstWhere((n) => n['id'] == 'agent:b')['own_provider'] =
        'cloud:xai'; // with no sign-in the app can start (round 2 #16)
    nodes.addAll([
      for (final id in ['cloud:openai', 'cloud:google', 'cloud:xai'])
        {'id': id, 'kind': 'cloud', 'column': 2, 'label': id, 'detail': ''},
    ]);
    graph['edges'] = [
      ...graph['edges'] as List,
      {'source': 'agent:b', 'target': 'cloud:google', 'kind': 'offer'},
    ];
    await mount(tester, edits: edits, graph: graph);
    Future<void> draw(String from, String to) async {
      await tester.dragFrom(
        tester.getCenter(find.text(from)),
        tester.getCenter(find.text(to)) - tester.getCenter(find.text(from)),
      );
      await tester.pump();
    }

    await draw('agent:a', 'cloud:google');
    expect(edits, isEmpty);
    expect(find.text('agent:a cannot use cloud:google.'), findsOneWidget);
    await draw('agent:b', 'cloud:google');
    expect(edits, isEmpty);
    expect(
      find.text(
        'To switch agent:b to cloud:google, draw the line to one of its models.',
      ),
      findsOneWidget,
    );
    await draw('agent:b', 'cloud:xai');
    expect(edits, isEmpty);
    expect(
      find.text('This agent has no sign-in that the app can start.'),
      findsOneWidget,
    );
    // Its own provider: the edit (a sign-in) goes ahead.
    await draw('agent:a', 'cloud:openai');
    expect(edits.single['target'], 'cloud:openai');
    expect(tester.takeException(), isNull);
  });
  testWidgets('a working agent that calls another one keeps the map (0.13.0)', (
    tester,
  ) async {
    // The graph as the app hands it over: decoded JSON plus withAgentLinks.
    final graph =
        (jsonDecode(
                  jsonEncode({
                    ...fixtureGraph(active: true),
                    'activity': {
                      'a': {
                        'working': true,
                        'uses': ['b'],
                      },
                      'b': {'working': true},
                    },
                    'edges': [
                      ...fixtureGraph(active: true)['edges'] as List,
                      {
                        'source': 'agent:b',
                        'target': 'runtime:s',
                        'kind': 'uses',
                        'active': true,
                        'activity': 'agent',
                      },
                    ],
                  }),
                )
                as Map)
            .cast<String, dynamic>();
    await mount(tester, edits: [], graph: withAgentLinks(graph));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.text('agent:b'), findsOneWidget);
  });
  test('the column counts what is on, not what only stays known', () {
    final groups = MapGroup.fromGraph(
      {
        'nodes': [
          {'id': 'mcp:a', 'column': 0},
          {'id': 'mcp:b', 'column': 0, 'dim': true},
        ],
      },
      ['MCP servers and skills'],
    );
    expect(groups.single.count, 1);
  });

  testWidgets('the card header filters to what is used, and back', (
    tester,
  ) async {
    final layouts = <Map<String, dynamic>>[];
    await mount(tester, edits: [], onLayout: layouts.add);
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is IconButton &&
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('card-used-only-'),
    );
    expect(toggle, findsWidgets);
    await tester.tap(toggle.first);
    await tester.pumpAndSettle();
    expect(layouts.last['used_only'], hasLength(1));
    await tester.tap(toggle.first);
    await tester.pumpAndSettle();
    expect(layouts.last['used_only'], isEmpty);
  });

  testWidgets('moving a model line onto a missing model says it is gone', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[];
    final graph = fixtureGraph();
    (graph['nodes'] as List).cast<Map<String, dynamic>>().singleWhere(
      (node) => node['id'] == 'model:r:n',
    )['status'] = 'missing';
    await mount(tester, edits: edits, graph: graph);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    // agent:a's line to model:r:m: the hook nearest that model.
    final model = tester.getCenter(find.text('model:r:m'));
    final hook =
        find
            .byTooltip(
              'Move this connection to another compatible box, or to empty space to disconnect.',
            )
            .evaluate()
            .map((e) => tester.getCenter(find.byWidget(e.widget)))
            .toList()
          ..sort(
            (a, b) => (a - model).distance.compareTo((b - model).distance),
          );
    await tester.dragFrom(
      hook.first,
      tester.getCenter(find.text('model:r:n')) - hook.first,
    );
    await tester.pump();
    expect(edits, isEmpty);
    expect(find.text('This model is no longer on this PC.'), findsOneWidget);
    expect(
      find.text('Only a model from runtime:r can replace this one.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('a line that is not ours has no hook and says why', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[];
    final graph = fixtureGraph();
    await mount(tester, edits: edits);
    final hooks = find.byTooltip(
      'Move this connection to another compatible box, or to empty space to disconnect.',
    );
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    final count = hooks.evaluate().length;
    final onLine = tester.getCenter(hooks.first);
    await tester.pumpWidget(const SizedBox());
    for (final edge in (graph['edges'] as List).cast<Map>()) {
      edge['fixed'] = 'through a folder it reads';
    }
    await mount(tester, edits: edits, graph: graph);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    expect(count, greaterThan(0));
    expect(hooks, findsNothing);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    await tester.tapAt(onLine);
    await tester.pumpAndSettle();
    expect(edits.single['fixed'], isNotNull);
  });
  testWidgets('an add card ends the MCP and model folder cards', (
    tester,
  ) async {
    final added = <(String, String)>[];
    await mount(tester, edits: [], onAdd: (k, t) => added.add((k, t)));
    expect(find.byKey(const ValueKey('card-add-0:mcp:')), findsOneWidget);
    expect(find.text('Add MCP server'), findsOneWidget);
    expect(find.text('Add model'), findsOneWidget);
    expect(find.byKey(const ValueKey('card-add-1:agent:')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('card-add-3:model:')));
    await tester.tap(find.byKey(const ValueKey('card-add-0:mcp:')));
    await tester.pump();
    expect(added, [('model', 'r'), ('mcp', '')]);
    // Without a handler there is nothing to tap.
    await tester.pumpWidget(const SizedBox());
    await mount(tester, edits: []);
    expect(find.byKey(const ValueKey('card-add-0:mcp:')), findsNothing);
  });
  testWidgets('a program to install ends the Agents card, with its menu', (
    tester,
  ) async {
    final asked = <(String, String)>[];
    final graph = {
      ...fixtureGraph(),
      'missing': [
        {'command': 'codex', 'name': 'Codex', 'addon': 'agent-codex'},
      ],
    };
    await mount(
      tester,
      edits: [],
      graph: graph,
      onMissing: (_, action, item) =>
          asked.add((action, item['addon'] as String)),
    );
    final card = find.byKey(const ValueKey('card-missing-codex'));
    expect(card, findsOneWidget);
    expect(find.text('Codex · Not installed'), findsOneWidget);
    await tester.tap(find.text('Codex · Not installed'));
    await tester.pump();
    for (final item in ['Add-on…', 'Switch off', 'Install {0}…']) {
      await tester.tap(
        find.descendant(of: card, matching: find.byTooltip('Actions')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(item.replaceAll('{0}', 'Codex')).last);
      await tester.pumpAndSettle();
    }
    expect(asked, [
      ('install', 'agent-codex'),
      ('details', 'agent-codex'),
      ('off', 'agent-codex'),
      ('install', 'agent-codex'),
    ]);
    // Without a handler there is nothing to tap.
    await tester.pumpWidget(const SizedBox());
    await mount(tester, edits: [], graph: graph);
    expect(card, findsNothing);
  });
  testWidgets('a click on a line shows its hook; empty space hides it', (
    tester,
  ) async {
    await mount(tester, edits: []);
    final hooks = find.byTooltip(
      'Move this connection to another compatible box, or to empty space to disconnect.',
    );
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    final onLine = tester.getCenter(hooks.first);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    expect(hooks, findsNothing);
    await tester.tapAt(onLine);
    await tester.pumpAndSettle();
    expect(hooks, findsOneWidget);
    await tester.tapAt(onLine + const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(hooks, findsNothing);

    // Drawing from a box ends the click; the line's own hook can be dragged.
    await tester.tapAt(onLine);
    await tester.pumpAndSettle();
    final edits = find.text('agent:a');
    final gesture = await tester.startGesture(tester.getCenter(edits));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(hooks, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
  });
  testWidgets(
    'selected line hook removes on empty and Escape cancels keyboard move',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      final hooks = find.byTooltip(
        'Move this connection to another compatible box, or to empty space to disconnect.',
      );
      // Its provider line only: its model hangs off the provider (r → m).
      expect(hooks, findsOneWidget);
      await tester.drag(hooks.first, const Offset(0, 300));
      await tester.pump();
      expect(edits.single['target'], isNull);
      expect(edits.single['edge']['kind'], 'uses');
      edits.clear();
      await tester.tap(hooks.first);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
      expect(edits, isEmpty);
    },
  );
  testWidgets('a column border drags its width; a double click restores it', (
    tester,
  ) async {
    final saved = <Map<String, dynamic>>[];
    await mount(tester, edits: [], onLayout: saved.add);
    final edge = find.byKey(const ValueKey('column-edge-agents-right'));
    await tester.drag(edge, const Offset(40, 0));
    await tester.pumpAndSettle();
    final widths = saved.last['column_widths'] as Map;
    expect(widths.keys, ['agents']);
    expect(widths['agents'], greaterThan(266));
    await tester.tap(edge);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(edge);
    await tester.pumpAndSettle();
    expect(saved.last['column_widths'], isEmpty);
  });

  testWidgets(
    'Show faded lines off: a selection draws only its own lines, no faded ones',
    (tester) async {
      Future<int> pathsWithSelection(Map<String, dynamic> saved) async {
        // agent:b's own line has nothing to do with agent:a's selection.
        final graph = fixtureGraph();
        (graph['edges'] as List).add({
          'source': 'agent:b',
          'target': 'runtime:s',
          'kind': 'uses',
        });
        await tester.pumpWidget(const SizedBox()); // a fresh map, no selection
        await mount(tester, edits: [], saved: saved, graph: graph);
        await tester.tap(find.text('agent:a'));
        await tester.pumpAndSettle();
        final map = tester.renderObject(
          find.byWidgetPredicate(
            (w) =>
                w is CustomPaint &&
                w.painter.runtimeType.toString() == '_MapPaint',
          ),
        );
        var paths = 0;
        expect(
          map,
          paints..everything((method, args) {
            if (method == #drawPath) paths++;
            return true;
          }),
        );
        return paths;
      }

      final faded = await pathsWithSelection({});
      final hidden = await pathsWithSelection({'dim_lines': false});
      expect(hidden, greaterThan(0));
      expect(hidden, lessThan(faded));
    },
  );

  testWidgets('a selection grays out the rest, but not what is pinned', (
    tester,
  ) async {
    await mount(tester, edits: []);
    double shade(String label) => tester
        .widget<Opacity>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    await tester.tap(find.byKey(const ValueKey('pin-agent:b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    expect(shade('agent:a'), 1);
    expect(shade('agent:b'), 1);
    // A selected box stands out from what is merely lit.
    double outline(String label) =>
        ((tester
                        .widget<Card>(
                          find
                              .ancestor(
                                of: find.text(label),
                                matching: find.byType(Card),
                              )
                              .first,
                        )
                        .shape
                    as RoundedRectangleBorder)
                .side)
            .width;
    expect(outline('agent:a'), 3);
    expect(outline('agent:b'), 1);

    // A provider lights its model in use, not models merely in its folder.
    await tester.tap(find.byKey(const ValueKey('pin-agent:b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('runtime:r'));
    await tester.pumpAndSettle();
    expect(shade('model:r:m'), 1);
    expect(shade('model:r:n'), lessThan(1));
    await tester.tap(find.text('runtime:r'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pin-agent:b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();

    // A pin lights itself, not its neighbours.
    await tester.tap(find.byKey(const ValueKey('pin-agent:b')));
    await tester.tap(find.byKey(const ValueKey('pin-agent:a')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('agent:b'));
    await tester.pumpAndSettle();
    expect(shade('agent:a'), 1);
    expect(shade('runtime:r'), lessThan(1));
    // A faded box still hides the lines passing under it.
    final faded = find.byKey(const ValueKey('box-backing-runtime:r'));
    expect(tester.widget<Card>(faded).color?.a, 1);
    expect(
      find.descendant(
        of: find.ancestor(of: faded, matching: find.byType(Stack)).first,
        matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
      findsWidgets,
    );
    // A second click ends it, and a pin keeps its light.
    await tester.tap(find.text('agent:b'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
      findsNothing,
    );
    await tester.tap(find.text('agent:b'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
      findsWidgets,
    );

    // A click on empty map ends the selection.
    final board = tester.getTopLeft(find.byType(InteractiveViewer));
    await tester.tapAt(board + const Offset(6, 600));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
      findsNothing,
    );
  });

  testWidgets(
    'fold and keyboard reorder save only layout; pin survives remount',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, onLayout: saved.add);
      await tester.tap(find.byKey(const ValueKey('pin-agent:a')));
      await tester.pumpAndSettle();
      expect(saved.last['pins'], ['agent:a']);
      expect(edits, isEmpty);
      await tester.tap(find.byTooltip('Collapse').first);
      await tester.pumpAndSettle();
      expect(saved.last['collapsed'], isNotEmpty);
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lights stop with reduced motion, off setting and widget removal',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, active: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(MapLightLayer), findsOneWidget);
      expect(
        (tester.widget<MapLightLayer>(find.byType(MapLightLayer)).clock
                as MapLightClock)
            .enabled,
        true,
      );
      await mount(tester, edits: edits, active: true, reduced: true);
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      await mount(tester, edits: edits, active: true, mode: 'off');
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'one agent selected with Shift; a click on a model only selects it',
    (tester) async {
      final edits = <Map<String, dynamic>>[], selection = <String>{};
      await mount(tester, edits: edits, selection: selection);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text('agent:b'));
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(selection, {'agent:b'});
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('model:r:n'));
      await tester.pump();
      expect(edits, isEmpty);
      expect(selection, {'model:r:n'});

      // Connecting stays a deliberate step.
      await tester.tap(find.byTooltip('Actions').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('model:r:n'));
      await tester.pump();
      expect(edits.single, {'source': 'agent:a', 'target': 'model:r:n'});
    },
  );
  testWidgets(
    'keyboard Connect uses the same reviewed edit and card movement saves layout',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, onLayout: saved.add);
      await tester.tap(find.byTooltip('Actions').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('runtime:s'));
      await tester.pumpAndSettle();
      expect(edits.single, {'source': 'agent:a', 'target': 'runtime:s'});
      edits.clear();
      await tester.drag(find.text('Online agents'), const Offset(40, 60));
      await tester.pumpAndSettle();
      expect((saved.last['card_order'] as List), contains('1:agent:'));
      expect(saved.last.containsKey('cards'), false);
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'group cards stay in their column with 2 px drop line and Earlier/Later menu only',
    (tester) async {
      final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
      final base = fixtureGraph();
      final graph = {
        ...base,
        'nodes': [
          ...(base['nodes'] as List),
          {
            'id': 'skills:s',
            'kind': 'skills',
            'column': 0,
            'label': 'skills:s',
            'detail': '',
          },
        ],
      };
      await mount(
        tester,
        edits: edits,
        graph: graph,
        saved: {
          'cards': {
            '0:mcp:': [600, 400],
          },
        },
        onLayout: saved.add,
      );
      final mcpHeader = find
          .ancestor(
            of: find.text('MCP servers'),
            matching: find.byType(Positioned),
          )
          .first;
      final skillsHeader = find
          .ancestor(of: find.text('Skills'), matching: find.byType(Positioned))
          .first;
      expect(tester.getTopLeft(mcpHeader).dx, 17);
      expect(tester.getTopLeft(skillsHeader).dx, 17);
      expect(
        tester.getTopLeft(mcpHeader).dy,
        lessThan(tester.getTopLeft(skillsHeader).dy),
      );

      // Header menu only has Earlier card and Later card (the four Move items are gone).
      await tester.tap(
        find.descendant(
          of: mcpHeader,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Earlier card'), findsOneWidget);
      expect(find.text('Later card'), findsOneWidget);
      expect(find.text('Move left'), findsNothing);
      expect(find.text('Move right'), findsNothing);
      expect(find.text('Move up'), findsNothing);
      expect(find.text('Move down'), findsNothing);
      // Trying Earlier card on the top card in column 0 keeps it in column 0 at index 0.
      await tester.tap(find.text('Earlier card'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(mcpHeader).dx, 17);
      expect(
        tester.getTopLeft(mcpHeader).dy,
        lessThan(tester.getTopLeft(skillsHeader).dy),
      );

      // Vertical drag shows the 2 px drop line inside the column and reorders on release,
      // while horizontal offset cannot move the card out of its column.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('MCP servers')),
      );
      await gesture.moveBy(const Offset(250, 260));
      await tester.pump();
      final dropLine = find.byKey(const ValueKey('card-drop-line'));
      expect(dropLine, findsOneWidget);
      final lineRect = tester.getRect(dropLine);
      expect(lineRect.left, 17);
      expect(lineRect.width, 266);
      expect(lineRect.height, 2);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dropLine, findsNothing);
      expect(tester.getTopLeft(mcpHeader).dx, 17);
      expect(tester.getTopLeft(skillsHeader).dx, 17);
      expect(
        tester.getTopLeft(skillsHeader).dy,
        lessThan(tester.getTopLeft(mcpHeader).dy),
      );
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reorder grip and provider hook preserve scene coordinates', (
    tester,
  ) async {
    final edits = <Map<String, dynamic>>[], saved = <Map<String, dynamic>>[];
    await mount(tester, edits: edits, onLayout: saved.add);
    await tester.drag(
      find.byKey(const ValueKey('reorder-agent:a')),
      const Offset(0, 160),
    );
    await tester.pumpAndSettle();
    expect((saved.last['order'] as Map)['1:agent:'], ['agent:b', 'agent:a']);
    await tester.tap(find.text('agent:a'));
    await tester.pumpAndSettle();
    final hook = find
        .byTooltip(
          'Move this connection to another compatible box, or to empty space to disconnect.',
        )
        .first;
    final from = tester.getCenter(hook),
        to = tester.getCenter(find.text('runtime:s'));
    await tester.dragFrom(from, to - from);
    await tester.pumpAndSettle();
    expect(edits.single['target'], 'runtime:s');
    expect(edits.single['edge']['kind'], 'uses');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'connecting works by keyboard: Actions › Connect, Enter on the target',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits);
      Finder box(String label) => find
          .ancestor(of: find.text(label), matching: find.byType(Card))
          .first;
      // Tab until the focus is inside `target`.
      Future<void> tabTo(Finder target) async {
        final element = target.evaluate().single;
        for (var i = 0; i < 80; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused == null) continue;
          var inside = focused == element;
          focused.visitAncestorElements((e) {
            if (e == element) inside = true;
            return !inside;
          });
          if (inside) return;
        }
        fail('not reachable by Tab');
      }

      await tabTo(
        find.descendant(
          of: box('agent:a'),
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Connect
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tabTo(box('runtime:r'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(edits.single, {'source': 'agent:a', 'target': 'runtime:r'});
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card slot is hidden without helpers, changes no node or transform when opened, keeps one open, and fits Omarchy popup',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: false);
      expect(find.byType(MapSmartCard), findsNothing);

      final controller = TransformationController()
        ..value = (Matrix4.identity()..translateByDouble(10, 12, 0, 1));
      addTearDown(controller.dispose);
      final popup = Size(
        popupSize.width.toDouble(),
        popupSize.height.toDouble(),
      );
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        controller: controller,
        size: popup,
      );
      await tester.pump(); // the map has fitted the window
      expect(find.byType(MapSmartCard), findsNWidgets(4));
      for (final (col, _) in mapSmartColumns) {
        final card = tester.widget<MapSmartCard>(
          find.byKey(ValueKey('smart-card-$col')),
        );
        expect(card.open, isFalse);
        expect(
          tester.getSize(find.byKey(ValueKey('smart-card-$col'))),
          const Size(266, 38),
        );
      }

      Map<String, Rect> nodeRects() => {
        for (final label in [
          'agent:a',
          'agent:b',
          'runtime:r',
          'runtime:s',
          'model:r:m',
          'model:r:n',
          'mcp:c',
        ])
          label: tester.getRect(find.text(label)),
      };
      final beforeNodes = nodeRects();
      final beforeMatrix = controller.value.clone();

      // Open the Agents smart card: node positions and transform do not change.
      await tester.tap(find.byKey(const ValueKey('smart-card-agents')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .open,
        isTrue,
      );
      expect(nodeRects(), beforeNodes);
      expect(controller.value, beforeMatrix);
      final agentsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-agents')),
      );
      expect(agentsRect.left, greaterThanOrEqualTo(0));
      expect(agentsRect.top, greaterThanOrEqualTo(0));
      expect(agentsRect.right, lessThanOrEqualTo(popup.width));
      expect(agentsRect.bottom, lessThanOrEqualTo(popup.height));

      // At scale 0.8 in the 1100 × 760 Omarchy popup, the 4 columns are centred
      // in 1100 / 0.8 = 1375 px (Models column board left 1007) and already fully
      // in view: opening it keeps board left at 1007 and does not touch the
      // transform or any node position.
      controller.value = Matrix4.diagonal3Values(0.8, 0.8, 1);
      await tester.pump();
      final scaledNodes = nodeRects();
      final scaledMatrix = controller.value.clone();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-card-models')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .open,
        isFalse,
      );
      expect(
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-models')),
            )
            .open,
        isTrue,
      );
      expect(
        find.byWidgetPredicate((w) => w is MapSmartCard && w.open),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Positioned>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('smart-card-models')),
                    matching: find.byType(Positioned),
                  )
                  .first,
            )
            .left,
        1007,
      );
      expect(nodeRects(), scaledNodes);
      expect(controller.value, scaledMatrix);
      final scaledModelsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-models')),
      );
      expect(scaledModelsRect.left, greaterThanOrEqualTo(0));
      expect(scaledModelsRect.right, lessThanOrEqualTo(popup.width));
      expect(scaledModelsRect.bottom, lessThanOrEqualTo(popup.height));

      // When cut off at scale 1.0 in 1100 × 760, opening Models keeps board left at 922
      // and brings it into view through the transform.
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      controller.value = Matrix4.identity();
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('smart-card-models')),
          matching: find.text('Ask AI…'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Positioned>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('smart-card-models')),
                    matching: find.byType(Positioned),
                  )
                  .first,
            )
            .left,
        922,
      );
      final modelsRect = tester.getRect(
        find.byKey(const ValueKey('smart-card-models')),
      );
      expect(modelsRect.left, greaterThanOrEqualTo(0));
      expect(modelsRect.top, greaterThanOrEqualTo(0));
      expect(modelsRect.right, lessThanOrEqualTo(popup.width));
      expect(modelsRect.bottom, lessThanOrEqualTo(popup.height));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'open smart card sits above line handles so tapping over a handle does not reach it',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: true);
      await tester.tap(find.text('agent:a'));
      await tester.pumpAndSettle();
      final hook = find
          .byTooltip(
            'Move this connection to another compatible box, or to empty space to disconnect.',
          )
          .first;
      final hookCenter = tester.getCenter(hook);

      await tester.tap(find.byKey(const ValueKey('smart-card-providers')));
      await tester.pumpAndSettle();
      await tester.tapAt(hookCenter);
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
      await tester.dragFrom(hookCenter, const Offset(0, 240));
      await tester.pump();
      expect(edits, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'opening smart card focuses the text field; Esc and Close return focus to the collapsed bar',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      await mount(tester, edits: edits, smartCards: true);
      final agentsCard = find.byKey(const ValueKey('smart-card-agents'));

      bool focusInside(Finder finder) {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) return false;
        final target = finder.evaluate().single;
        var inside = focused == target;
        focused.visitAncestorElements((e) {
          if (e == target) inside = true;
          return !inside;
        });
        return inside;
      }

      // Opening focuses the TextField inside the open smart card.
      await tester.tap(agentsCard);
      await tester.pumpAndSettle();
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(TextField)),
        ),
        isTrue,
      );

      // Pressing Escape closes the card and returns focus to its collapsed bar.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(InkWell)).last,
        ),
        isTrue,
      );

      // Re-open with Enter on the focused collapsed bar, then click Close:
      // focus returns to the collapsed bar again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isTrue);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(TextField)),
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(
        focusInside(
          find.descendant(of: agentsCard, matching: find.byType(InkWell)).last,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card states 1 to 6: 16 px status slot, helper cost before Ask, working cancel, clarify, redirect move, and error try again',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      final calls = <(String, Map<String, dynamic>)>[];
      var nextTaskState = 'running';
      Map<String, dynamic> nextResult = const {};
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add((method, Map<String, dynamic>.from(params)));
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'task-1'};
            case 'tasks.status':
              return {
                'state': nextTaskState,
                if (nextTaskState == 'done') 'result': nextResult,
              };
            case 'tasks.cancel':
              return {'cancelled': true};
            default:
              throw StateError('Unexpected method $method');
          }
        }),
      );
      const helpers = [
        {'command': 'local-helper', 'name': 'Local helper', 'local': true},
        {'command': 'claude', 'name': 'Claude Code', 'local': false},
      ];
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        smartHelpers: helpers,
        client: client,
      );

      // State 2: collapsed bar reserves a 16 px slot at its left and shows the default helper.
      final slots = find.byKey(const ValueKey('smart-status-slot'));
      expect(slots, findsNWidgets(4));
      expect(tester.getSize(slots.first), const Size(16, 16));
      expect(find.text(' · Local helper'), findsNWidgets(4));

      // Open Agents smart card (State 3: Idle).
      final agentsCard = find.byKey(const ValueKey('smart-card-agents'));
      await tester.tap(agentsCard);
      await tester.pumpAndSettle();
      expect(find.text('Local, no tokens'), findsOneWidget);
      expect(find.text('Set up or connect an agent…'), findsOneWidget);

      // Switching helper shows Uses plan/tokens before Ask; no request sent yet.
      await tester.tap(find.byKey(const ValueKey('smart-helper-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude Code').last);
      await tester.pumpAndSettle();
      expect(find.text('Uses plan/tokens'), findsOneWidget);
      expect(calls, isEmpty);
      // The choice holds for every card, with its check mark.
      expect(smartHelperChosen.value, 'claude');
      expect(
        find.byKey(const ValueKey('smart-helper-chosen')),
        findsNWidgets(4),
      );

      // Clicking Ask with blank prompt sends nothing.
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pump();
      expect(calls, isEmpty);

      // Typing text does not send; only clicking Ask sends map.smart_ask (State 4: Working).
      await tester.enterText(
        find.descendant(of: agentsCard, matching: find.byType(TextField)),
        'install qwencoder',
      );
      await tester.pump();
      expect(calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pump();
      expect(calls.first.$1, 'map.smart_ask');
      expect(calls.first.$2, {
        'column': 'agents',
        'command': 'claude',
        'request': 'install qwencoder',
      });
      expect(find.text('Claude Code is checking Agents…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Cancel in Working cancels the task and returns to Idle with the text kept.
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls.any((c) => c.$1 == 'tasks.cancel'), isTrue);
      expect(find.text('install qwencoder'), findsOneWidget);

      // State 6: Redirect on a column that is not Models, with Move to Models.
      calls.clear();
      nextTaskState = 'done';
      nextResult = {
        'helper': 'Claude Code',
        'local': false,
        'status': 'redirect',
        'instead': {
          'hint': 'Models are managed in the Models column.',
          'column': 'models',
          'request': 'install qwencoder',
        },
      };
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(
        find.text('Models are managed in the Models column.'),
        findsOneWidget,
      );
      expect(find.text('Move to Models'), findsOneWidget);

      // Clicking Move to Models opens Models card and pre-fills prompt without auto-sending.
      calls.clear();
      await tester.tap(find.text('Move to Models'));
      await tester.pumpAndSettle();
      final modelsCard = find.byKey(const ValueKey('smart-card-models'));
      expect(tester.widget<MapSmartCard>(agentsCard).open, isFalse);
      expect(tester.widget<MapSmartCard>(modelsCard).open, isTrue);
      expect(calls, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: modelsCard, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        'install qwencoder',
      );

      // State 5: Clarify shows question and choice chips; clicking a chip sends answer.
      // Back to the local helper, for all cards.
      smartHelperChosen.value = null;
      await tester.pump();
      nextResult = {
        'helper': 'Local helper',
        'local': true,
        'status': 'clarify',
        'question': 'Which local LLM should run this model?',
        'choices': ['Ollama', 'llama.cpp'],
      };
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(
        find.text('Which local LLM should run this model?'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: modelsCard,
          matching: find.text('Local, no tokens'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: modelsCard, matching: find.text('Local helper')),
        findsOneWidget,
      );
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('llama.cpp'), findsOneWidget);

      // Clicking a choice chip sends map.smart_ask with answer; if it returns error,
      // Try again returns to prompt with text kept (no auto-retry).
      calls.clear();
      nextResult = {
        'helper': 'Local helper',
        'local': true,
        'status': 'error',
        'summary': 'Could not reach the search service.',
      };
      await tester.tap(find.text('Ollama'));
      await tester.pumpAndSettle();
      expect(calls.first.$1, 'map.smart_ask');
      expect(calls.first.$2, {
        'column': 'models',
        'command': 'local-helper',
        'request': 'install qwencoder',
        'answer': 'Ollama',
      });
      expect(find.text('Could not reach the search service.'), findsOneWidget);
      calls.clear();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: modelsCard, matching: find.byType(TextField)),
            )
            .controller
            ?.text,
        'install qwencoder',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card states 7 to 10: proposal words fit, omits Review on too_large, reviews and runs download, then connects via ConnectionReview',
    (tester) async {
      final edits = <Map<String, dynamic>>[];
      final calls = <(String, Map<String, dynamic>)>[];
      final applied = <Map<String, dynamic>>[];
      const gib = 1024 * 1024 * 1024;
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add((method, Map<String, dynamic>.from(params)));
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'ask-task'};
            case 'tasks.status':
              final task = params['task'] as String;
              if (task == 'ask-task') {
                return {
                  'state': 'done',
                  'result': {
                    'helper': 'Local helper',
                    'local': true,
                    'status': 'proposal',
                    'proposal': 'prop-1',
                    'summary': 'Found 3 models for Ollama.',
                    'limits': {
                      'gpu_name': 'AMD Radeon',
                      'vram': 12 * gib,
                      'ram': 32 * gib,
                      'free_disk': 80 * gib,
                    },
                    'candidates': [
                      {
                        'id': 'c1',
                        'title': 'Qwen2.5-Coder-7B-Q4_K_M.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-7B-GGUF · Ollama',
                        'reason': 'Fast coding model.',
                        'fit': 'ok',
                        'size': 5 * gib,
                        // From the core: the agents that can use a local LLM.
                        'connect': [
                          {'command': 'pi', 'name': 'Pi'},
                        ],
                      },
                      {
                        'id': 'c2',
                        'title': 'Qwen2.5-Coder-14B-Q4_K_M.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-14B-GGUF · Ollama',
                        'reason': 'Larger coding model.',
                        'fit': 'tight',
                        'size': 9 * gib,
                      },
                      {
                        'id': 'c3',
                        'title': 'Qwen2.5-Coder-72B-Q8_0.gguf',
                        'subtitle': 'bartowski/Qwen2.5-Coder-72B-GGUF · Ollama',
                        'reason': 'Exceeds memory.',
                        'fit': 'too_large',
                        'size': 75 * gib,
                      },
                    ],
                  },
                };
              }
              return {
                'state': 'done',
                'result': {'ok': true},
              };
            case 'map.smart_review':
              return {
                'title': 'Qwen2.5-Coder-7B-Q4_K_M.gguf',
                'subtitle': 'bartowski/Qwen2.5-Coder-7B-GGUF · Ollama',
                'size': 5 * gib,
                'fit': 'ok',
                'runtime': 'Ollama',
              };
            case 'map.smart_run':
              return {
                'task': 'run-task',
                'focus': ['runtime:ollama'],
              };
            case 'map.smart_connect':
              return {
                'plan': 'plan-1',
                'empty': false,
                'command': 'pi',
                'item': 'ollama',
                'remove': false,
                'files': [
                  {'path': '~/.pi/agent/models.json', 'added': 2, 'removed': 0},
                ],
                'links_add': [],
                'links_remove': [],
              };
            case 'connections.apply':
              return {'ok': true, 'undo': 'undo-1'};
            default:
              throw StateError('Unexpected method $method');
          }
        }),
      );
      const helpers = [
        {'command': 'local-helper', 'name': 'Local helper', 'local': true},
        {'command': 'claude', 'name': 'Claude Code', 'local': false},
      ];
      await mount(
        tester,
        edits: edits,
        smartCards: true,
        smartHelpers: helpers,
        client: client,
        onSmartApplied: applied.add,
      );

      final modelsCard = find.byKey(const ValueKey('smart-card-models'));
      await tester.tap(modelsCard);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: modelsCard, matching: find.byType(TextField)),
        'coding model for ollama',
      );
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();

      // State 7: Proposal shows PC limits, worded fit, and Review only on ok/tight.
      expect(find.text('Found 3 models for Ollama.'), findsOneWidget);
      expect(
        find.text('PC: 12.0 GiB VRAM · 32.0 GiB RAM · 80.0 GiB free'),
        findsOneWidget,
      );
      expect(find.text('Fits in VRAM'), findsOneWidget);
      expect(find.text('Uses RAM offload'), findsOneWidget);
      expect(find.text('Too large for this PC'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c2')), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c3')), findsNothing);

      // State 8: Clicking Review calls map.smart_review and shows SmartModelDownloadReview (TaskReview).
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'map.smart_review');
      expect(calls.last.$2, {'proposal': 'prop-1', 'candidate': 'c1'});
      expect(find.byType(SmartModelDownloadReview), findsOneWidget);
      expect(find.byType(TaskReview), findsOneWidget);
      expect(
        find.text('Download Qwen2.5-Coder-7B-Q4_K_M.gguf?'),
        findsOneWidget,
      );

      // Cancelling review keeps the proposal in State 7.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(SmartModelDownloadReview), findsNothing);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);

      // Re-open review and confirm: runs map.smart_run (State 9) and arrives at State 10 (Done).
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.$1 == 'map.smart_run'), isTrue);
      expect(
        find.text('Qwen2.5-Coder-7B-Q4_K_M.gguf is ready.'),
        findsOneWidget,
      );
      expect(
        find.text('Connect it to an agent now? (Optional)'),
        findsOneWidget,
      );
      // The agents the core names (those the manual Connect offers), not
      // the helpers: Claude Code has no local LLM connector.
      expect(find.widgetWithText(ActionChip, 'Pi'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Claude Code'), findsNothing);
      expect(find.widgetWithText(ActionChip, 'Local helper'), findsNothing);

      // Clicking Pi calls map.smart_connect and shows ConnectionReview.
      await tester.tap(find.widgetWithText(ActionChip, 'Pi'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'map.smart_connect');
      expect(calls.last.$2, {
        'proposal': 'prop-1',
        'candidate': 'c1',
        'agent': 'pi',
      });
      expect(find.byType(ConnectionReview), findsOneWidget);

      // Clicking Apply in ConnectionReview calls connections.apply, records Undo, and closes the card.
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, 'connections.apply');
      expect(calls.last.$2, {'plan': 'plan-1'});
      expect(applied.last['undo'], 'undo-1');
      expect(tester.widget<MapSmartCard>(modelsCard).open, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smart card texts exist in all 8 languages and steps are operable by keyboard',
    (tester) async {
      const smartKeys = [
        'Ask AI…',
        'Ask AI',
        'Ask AI · {0}',
        'Ask for this column…',
        'Back',
        'Local, no tokens',
        'Uses plan/tokens',
        'Ask',
        'Find an MCP server or skill…',
        'Set up or connect an agent…',
        'Set up or tune a provider…',
        'Find or connect a model…',
        '{0} is checking {1}…',
        'Ask again',
        'Move to {0}',
        'Try again',
        'PC: {0} VRAM · {1} RAM · {2} free',
        'PC: {0} RAM · {1} free',
        'Fits in VRAM',
        'Uses RAM offload',
        'Too large for this PC',
        'Review',
        'Download {0}?',
        'Runtime',
        '{0} is ready.',
        'Connect it to an agent now? (Optional)',
        'Done',
      ];
      for (final lang in ['de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
        final file = File('../translations/$lang.json');
        final table = jsonDecode(file.readAsStringSync()) as Map;
        for (final key in smartKeys) {
          expect(
            table[key],
            isA<String>(),
            reason: 'Missing $lang translation for $key',
          );
          expect((table[key] as String).isNotEmpty, isTrue);
        }
      }

      // Keyboard navigation through the smart card with German translations.
      final deTable =
          jsonDecode(File('../translations/de.json').readAsStringSync()) as Map;
      final calls = <String>[];
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add(method);
          if (method == 'map.smart_ask') return {'task': 't1'};
          if (method == 'tasks.status') {
            return {
              'state': 'done',
              'result': {
                'helper': 'Local helper',
                'local': true,
                'status': 'redirect',
                'instead': {'hint': 'Nur Modelle.'},
              },
            };
          }
          throw StateError('Unexpected $method');
        }),
      );
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var isOpen = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => MapSmartCard(
                column: 'models',
                title: 'Models',
                open: isOpen,
                onToggle: () => update(() => isOpen = !isOpen),
                tr: (k) => deTable[k] is String ? deTable[k] as String : k,
                helpers: const [
                  {
                    'command': 'local-helper',
                    'name': 'Lokaler Helfer',
                    'local': true,
                  },
                ],
                client: client,
              ),
            ),
          ),
        ),
      );
      expect(find.text('KI fragen…'), findsOneWidget);
      await tester.tap(find.text('KI fragen…'));
      await tester.pumpAndSettle();
      expect(find.text('Lokal, keine Tokens'), findsOneWidget);
      expect(find.text('Modell finden oder verbinden…'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'qwen');
      // Enter in the field asks (as the Launcher); Ctrl+Enter is a new line.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'qwen\n',
      );
      expect(calls, isNot(contains('map.smart_ask')));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(calls, contains('map.smart_ask'));
      expect(find.text('Nur Modelle.'), findsOneWidget);
      expect(find.text('Erneut fragen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'collapsing or pressing Esc during a run keeps the download going; collapsing during working returns to a usable prompt',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final calls = <String>[];
      var askDone = false;
      var runDone = false;
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          calls.add(method);
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'ask-1'};
            case 'map.smart_review':
              return {
                'title': 'Qwen 2.5 Coder 7B',
                'subtitle': 'Q4_K_M',
                'size': 4683073920,
                'fit': 'ok',
                'runtime': 'Ollama',
              };
            case 'map.smart_run':
              return {'task': 'run-1'};
            case 'tasks.cancel':
              return {'state': 'stopped'};
            case 'tasks.status':
              if (params['task'] == 'ask-1') {
                if (!askDone) {
                  return {'state': 'running'};
                }
                return {
                  'state': 'done',
                  'result': {
                    'helper': 'Local helper',
                    'local': true,
                    'status': 'proposal',
                    'proposal': 'prop-1',
                    'summary': 'Found 1 model.',
                    'limits': {
                      'vram': 8589934592,
                      'ram': 17179869184,
                      'free_disk': 53687091200,
                    },
                    'candidates': [
                      {
                        'id': 'c1',
                        'title': 'Qwen 2.5 Coder 7B',
                        'subtitle': 'Q4_K_M',
                        'reason': 'Fast.',
                        'fit': 'ok',
                        'size': 4683073920,
                      },
                    ],
                  },
                };
              }
              if (params['task'] == 'run-1') {
                if (!runDone) {
                  return {
                    'state': 'running',
                    'fraction': 0.5,
                    'text': 'Downloading 50%…',
                  };
                }
                return {
                  'state': 'done',
                  'result': {'ok': true},
                };
              }
              throw StateError('Unknown task ${params['task']}');
            default:
              throw StateError('Unexpected $method');
          }
        }),
      );

      var isOpen = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) => MapSmartCard(
                column: 'models',
                title: 'Models',
                open: isOpen,
                onToggle: () => update(() => isOpen = !isOpen),
                tr: (k) => k,
                helpers: const [
                  {
                    'command': 'local-helper',
                    'name': 'Local helper',
                    'local': true,
                  },
                ],
                client: client,
              ),
            ),
          ),
        ),
      );

      // 1. Back during working cancels the ask and returns to the main Ask AI
      // page with the text kept; Back there goes to the map.
      await tester.tap(find.text('Ask AI…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'qwen coder');
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pump();
      expect(find.text('Local helper is checking Models…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      expect(isOpen, isTrue);
      expect(calls, contains('tasks.cancel'));
      expect(find.widgetWithText(TextField, 'qwen coder'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-send')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pumpAndSettle();
      expect(isOpen, isFalse);

      // Reopen: prompt is back in idle state with 'qwen coder' preserved and Ask usable.
      calls.clear();
      await tester.tap(find.text('Ask AI…'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'qwen coder'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-send')), findsOneWidget);

      // 2. Start ask -> proposal -> review -> running download.
      askDone = true;
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(find.text('Found 1 model.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Downloading 50%…'), findsOneWidget);

      // Collapse via button while download is running -> no tasks.cancel sent.
      calls.clear();
      await tester.tap(find.byKey(const ValueKey('smart-back')));
      await tester.pump();
      expect(isOpen, isFalse);
      expect(calls, isNot(contains('tasks.cancel')));

      // Reopen while still running -> still shows progress, then press Esc -> no tasks.cancel sent.
      await tester.tap(find.text('Ask AI…'));
      await tester.pump();
      expect(isOpen, isTrue);
      expect(find.text('Downloading 50%…'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(isOpen, isFalse);
      expect(calls, isNot(contains('tasks.cancel')));

      // Finish download in background while collapsed, then reopen -> shows done.
      runDone = true;
      await tester.pump(const Duration(milliseconds: 250));
      await tester.tap(find.text('Ask AI…'));
      await tester.pumpAndSettle();
      expect(find.text('Qwen 2.5 Coder 7B is ready.'), findsOneWidget);
      expect(calls, isNot(contains('tasks.cancel')));
    },
  );

  testWidgets(
    'tasks.status state "stopped" returns working to prompt and running download to proposal',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var askState = 'stopped';
      var runState = 'stopped';
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          switch (method) {
            case 'map.smart_ask':
              return {'task': 'ask-1'};
            case 'map.smart_review':
              return {
                'title': 'Qwen 2.5 Coder 7B',
                'subtitle': 'Q4_K_M',
                'size': 4683073920,
                'fit': 'ok',
                'runtime': 'Ollama',
              };
            case 'map.smart_run':
              return {'task': 'run-1'};
            case 'tasks.status':
              if (params['task'] == 'ask-1') {
                if (askState != 'done') return {'state': askState};
                return {
                  'state': 'done',
                  'result': {
                    'helper': 'Local helper',
                    'local': true,
                    'status': 'proposal',
                    'proposal': 'prop-1',
                    'summary': 'Found 1 model.',
                    'candidates': [
                      {
                        'id': 'c1',
                        'title': 'Qwen 2.5 Coder 7B',
                        'subtitle': 'Q4_K_M',
                        'reason': 'Fast.',
                        'fit': 'ok',
                        'size': 4683073920,
                      },
                    ],
                  },
                };
              }
              return {'state': runState};
            default:
              throw StateError('Unexpected $method');
          }
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapSmartCard(
              column: 'models',
              title: 'Models',
              open: true,
              onToggle: () {},
              tr: (k) => k,
              helpers: const [
                {
                  'command': 'local-helper',
                  'name': 'Local helper',
                  'local': true,
                },
              ],
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 1. Working task answering "stopped" returns to idle prompt with text kept.
      await tester.enterText(find.byType(TextField), 'qwen');
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'qwen'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-send')), findsOneWidget);

      // 2. Running download answering "stopped" returns to proposal, not error.
      askState = 'done';
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(find.text('Found 1 model.'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.text('Found 1 model.'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
    },
  );

  testWidgets(
    'after a failed download, "Try again" returns to the proposal (not the prompt) so the candidate can be started again without spending tokens',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var askCalls = 0;
      var runCalls = 0;
      var runState = 'failed';
      final client = CoreClient(
        _FakeSmartTransport((method, params) async {
          switch (method) {
            case 'map.smart_ask':
              askCalls++;
              return {'task': 'ask-1'};
            case 'map.smart_review':
              return {
                'title': 'Qwen 2.5 Coder 7B',
                'subtitle': 'Q4_K_M',
                'size': 4683073920,
                'fit': 'ok',
                'runtime': 'Ollama',
              };
            case 'map.smart_run':
              runCalls++;
              return {'task': 'run-$runCalls'};
            case 'tasks.status':
              if (params['task'] == 'ask-1') {
                return {
                  'state': 'done',
                  'result': {
                    'helper': 'Local helper',
                    'local': true,
                    'status': 'proposal',
                    'proposal': 'prop-1',
                    'summary': 'Found 1 model.',
                    'candidates': [
                      {
                        'id': 'c1',
                        'title': 'Qwen 2.5 Coder 7B',
                        'subtitle': 'Q4_K_M',
                        'reason': 'Fast.',
                        'fit': 'ok',
                        'size': 4683073920,
                      },
                    ],
                  },
                };
              }
              if (runState == 'done') {
                return {
                  'state': 'done',
                  'result': {'ok': true},
                };
              }
              return {'state': runState};
            default:
              throw StateError('Unexpected $method');
          }
        }),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapSmartCard(
              column: 'models',
              title: 'Models',
              open: true,
              onToggle: () {},
              tr: (k) => k,
              helpers: const [
                {
                  'command': 'local-helper',
                  'name': 'Local helper',
                  'local': true,
                },
              ],
              client: client,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'qwen');
      await tester.tap(find.byKey(const ValueKey('smart-send')));
      await tester.pumpAndSettle();
      expect(askCalls, 1);
      expect(find.text('Found 1 model.'), findsOneWidget);

      // Start download -> fails -> shows error.
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(runCalls, 1);
      expect(find.text('The action could not be completed.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      // Clicking "Try again" returns to the proposal (not the prompt) and starts again on Review -> Download.
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Found 1 model.'), findsOneWidget);
      expect(find.byKey(const ValueKey('smart-review-c1')), findsOneWidget);
      expect(askCalls, 1);

      runState = 'done';
      await tester.tap(find.byKey(const ValueKey('smart-review-c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(runCalls, 2);
      expect(askCalls, 1);
      expect(find.text('Qwen 2.5 Coder 7B is ready.'), findsOneWidget);
    },
  );

  group('the map fits the window', () {
    double scaleOf(TransformationController c) => c.value.entry(0, 0);

    testWidgets('narrow window zooms out, wider window follows', (
      tester,
    ) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      const narrow = Size(500, 800);
      await mount(tester, edits: [], controller: controller, size: narrow);
      await tester.pump();
      final small = scaleOf(controller);
      expect(small, lessThan(1));

      tester.view.physicalSize = const Size(700, 800);
      await mount(
        tester,
        edits: [],
        controller: controller,
        size: const Size(700, 800),
      );
      await tester.pump();
      expect(scaleOf(controller), greaterThan(small));
    });

    testWidgets('a zoom by the user stays until Ctrl+0', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        edits: [],
        controller: controller,
        size: const Size(500, 800),
      );
      await tester.pump();
      controller.value = Matrix4.diagonal3Values(1.5, 1.5, 1);
      await mount(
        tester,
        edits: [],
        controller: controller,
        size: const Size(700, 800),
      );
      await tester.pump();
      expect(scaleOf(controller), 1.5);

      zoomMap(controller, 0);
      await tester.pump();
      expect(scaleOf(controller), lessThan(1));
    });
  });

  group('map columns and zoom', () {
    Future<List<List<String>>> columns(
      WidgetTester tester, {
      required Size size,
      List<String> layers = const [
        'agents',
        'online',
        'local',
        'models',
        'mcp',
        'skills',
      ],
    }) async {
      final changed = <List<String>>[];
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapEditor(
              graph: fixtureGraph(),
              saved: const {},
              onEdit: (_) async {},
              tr: (s) => s,
              layers: layers,
              onLayers: changed.add,
            ),
          ),
        ),
      );
      await tester.pump();
      return changed;
    }

    FilterChip chip(WidgetTester tester, int col) =>
        tester.widget<FilterChip>(find.byKey(ValueKey('map-column-$col')));

    testWidgets('additional usage: on, off and not known', (tester) async {
      Future<void> show(Map<String, dynamic>? extra) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentUsage(
                tr: (s) => s,
                info: {
                  'model': '',
                  'plan': 'Max 5x',
                  'providers': const [],
                  'limits': const [],
                  'extra_usage': extra,
                },
              ),
            ),
          ),
        ),
      );
      await show({'on': true, 'url': 'https://example.test/usage'});
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
      expect(find.textContaining('it can cost extra'), findsOneWidget);
      expect(find.textContaining('https://example.test/usage'), findsOneWidget);
      await show({'on': false, 'url': ''});
      expect(find.textContaining('it stops at'), findsOneWidget);
      await show(null);
      expect(find.textContaining('Not known on this PC'), findsOneWidget);
    });

    test('the display width on Linux is already logical', () {
      const screen = Size(1920, 1080);
      expect(displayWidthIn(screen, 2, TargetPlatform.linux), 1920);
      expect(
        displayWidthIn(const Size(3840, 2160), 2, TargetPlatform.macOS),
        1920,
      );
      expect(
        mapViewSizeFor(windowWidth: 941, displayWidth: 1920),
        MapViewSize.small,
      );
    });

    testWidgets('every symbol fits the narrowest card on Linux', (
      tester,
    ) async {
      Widget symbol(IconData icon) => IconButton(
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
        onPressed: () {},
        icon: Icon(icon, size: 16),
      );
      tester.view.physicalSize = const Size(640, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MapEditor(
              graph: {
                ...fixtureGraph(),
                'activity': {
                  'a': {
                    'subagents_supported': true,
                    'active_subagents': 2,
                    'children': [{}, {}, {}],
                  },
                },
                'traffic': {
                  'a': {'connections': 7, 'rate_in': 1, 'rate_out': 1},
                },
              },
              saved: const {},
              onEdit: (_) async {},
              tr: (s) => s,
              onSubagents: (_) {},
              controls: (_) => Row(
                children: [
                  for (final icon in [
                    Icons.info_outline,
                    Icons.bar_chart_outlined,
                    Icons.play_arrow,
                    Icons.terminal,
                    Icons.stop,
                  ])
                    symbol(icon),
                ],
              ),
              layers: const ['agents', 'online', 'local'],
              onLayers: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

    testWidgets('many connections get a page instead of a long menu', (
      tester,
    ) async {
      final graph = fixtureGraph();
      final nodes = graph['nodes'] as List;
      final edges = graph['edges'] as List;
      for (var i = 0; i < 5; i++) {
        nodes.add({
          'id': 'mcp:$i',
          'kind': 'mcp',
          'column': 0,
          'label': 'server $i',
          'detail': '',
        });
        edges.add({'source': 'agent:a', 'target': 'mcp:$i', 'kind': 'mcp'});
      }
      await mount(tester, edits: [], graph: graph);
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(of: find.text('agent:a'), matching: find.byType(Card))
              .first,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Move connection:'), findsNothing);
      await tester.tap(find.text('Move connection…'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(SimpleDialogOption, 'server 4'),
        findsOneWidget,
      );
    });

    testWidgets('a narrow window shows agents and providers only', (
      tester,
    ) async {
      await columns(tester, size: const Size(1036, 900));
      expect(find.text('agent:a'), findsWidgets);
      expect(find.text('runtime:r'), findsWidgets);
      expect(find.text('mcp:c'), findsNothing);
      expect(find.text('model:r:m'), findsNothing);
      expect(chip(tester, 0).onSelected, isNotNull);
      expect(chip(tester, 3).selected, isFalse);
    });

    testWidgets('a wide window shows every column the filter keeps', (
      tester,
    ) async {
      await columns(tester, size: const Size(1600, 900));
      expect(find.text('mcp:c'), findsWidgets);
      expect(find.text('model:r:m'), findsWidgets);
      await columns(
        tester,
        size: const Size(1600, 900),
        layers: const ['agents', 'online', 'local', 'mcp', 'skills'],
      );
      await tester.pump();
      expect(find.text('model:r:m'), findsNothing);
      expect(find.text('mcp:c'), findsWidgets);
    });

    testWidgets('the filter turns a whole column off', (tester) async {
      final changed = await columns(tester, size: const Size(1600, 900));
      await tester.tap(find.byKey(const ValueKey('map-column-2')));
      // Models need a provider, so they go with it.
      expect(changed.single.toSet(), {'agents', 'mcp', 'skills'});
    });

    testWidgets('with agents and providers off a narrow window stays empty', (
      tester,
    ) async {
      await columns(
        tester,
        size: const Size(1036, 900),
        layers: const ['models', 'mcp', 'skills'],
      );
      expect(find.text('mcp:c'), findsNothing);
      expect(find.text('model:r:m'), findsNothing);
    });

    testWidgets('a column that needs another brings it along', (tester) async {
      final changed = await columns(
        tester,
        size: const Size(1600, 900),
        layers: const ['online', 'local', 'models'],
      );
      await tester.tap(find.byKey(const ValueKey('map-column-0')));
      expect(changed.single.toSet(), containsAll(['mcp', 'skills', 'agents']));
    });

    testWidgets(
      'small, medium and max views follow screen share or window width, and full screen gives max view',
      (tester) async {
        // Fallback window widths when display size is unknown or smaller:
        // small (< 1150): Agents, Providers; medium (< 1600): + Models; max (>= 1600): all four.
        expect(
          mapViewSizeFor(windowWidth: 1149, displayWidth: 0),
          MapViewSize.small,
        );
        expect(
          mapViewSizeFor(windowWidth: 1150, displayWidth: 0),
          MapViewSize.medium,
        );
        expect(
          mapViewSizeFor(windowWidth: 1599, displayWidth: 0),
          MapViewSize.medium,
        );
        expect(
          mapViewSizeFor(windowWidth: 1600, displayWidth: 0),
          MapViewSize.max,
        );
        // Window share of display: <= 55 % small, <= 80 % medium, > 80 % max.
        expect(
          mapViewSizeFor(windowWidth: 1100, displayWidth: 2000),
          MapViewSize.small,
        );
        expect(
          mapViewSizeFor(windowWidth: 1101, displayWidth: 2000),
          MapViewSize.medium,
        );
        expect(
          mapViewSizeFor(windowWidth: 1600, displayWidth: 2000),
          MapViewSize.medium,
        );
        expect(
          mapViewSizeFor(windowWidth: 1601, displayWidth: 2000),
          MapViewSize.max,
        );

        // Medium view (1300 px): Agents, Providers and Models shown; MCP/skills greyed with tooltip.
        await columns(tester, size: const Size(1300, 900));
        expect(find.text('agent:a'), findsWidgets);
        expect(find.text('runtime:r'), findsWidgets);
        expect(find.text('model:r:m'), findsWidgets);
        expect(find.text('mcp:c'), findsNothing);
        expect(chip(tester, 0).selected, isFalse);
        expect(chip(tester, 3).selected, isTrue);

        // A column the view leaves out can be turned on, and off again.
        await columns(tester, size: const Size(1036, 900));
        expect(find.text('model:r:m'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('map-column-3')));
        await tester.pump();
        await tester.pump();
        expect(find.text('model:r:m'), findsWidgets);
        expect(chip(tester, 3).selected, isTrue);
        await tester.tap(find.byKey(const ValueKey('map-column-0')));
        await tester.pump();
        await tester.pump();
        expect(find.text('mcp:c'), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('map-column-3')));
        await tester.pump();
        await tester.pump();
        expect(find.text('model:r:m'), findsNothing);
        expect(find.text('mcp:c'), findsWidgets);
      },
    );

    testWidgets('a connection move is cancelled when its column is hidden', (
      tester,
    ) async {
      final edits = <Map<String, dynamic>>[];
      var layers = const [
        'agents',
        'online',
        'local',
        'models',
        'mcp',
        'skills',
      ];
      late StateSetter rebuild;
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return MapEditor(
                  graph: fixtureGraph(),
                  saved: const {},
                  onEdit: (e) async => edits.add(e),
                  tr: (s) => s,
                  layers: layers,
                  onLayers: (next) => setState(() => layers = next),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      // The model in use hangs off its provider: runtime:r → model:r:m.
      await tester.tap(find.text('model:r:m'));
      await tester.pumpAndSettle();
      final hooks = find.byTooltip(
        'Move this connection to another compatible box, or to empty space to disconnect.',
      );
      await tester.tap(hooks.last);
      await tester.pump();
      expect(find.text('Disconnect'), findsOneWidget);

      // Hide the Models column while the connection move is active:
      // the move is cancelled and tapping another node does not emit an edit.
      rebuild(
        () => layers = const ['agents', 'online', 'local', 'mcp', 'skills'],
      );
      await tester.pump();
      expect(find.text('Disconnect'), findsNothing);
      expect(find.text('Cancel'), findsNothing);
      await tester.tap(find.text('runtime:s'));
      await tester.pump();
      expect(edits, isEmpty);
    });

    testWidgets(
      'agent cards show badges, compact symbols, traffic dialog, Details, and red Stop only while running',
      (tester) async {
        final base = fixtureGraph();
        final nodes = [
          for (final n in (base['nodes'] as List).cast<Map<String, dynamic>>())
            if (n['id'] == 'agent:a')
              {...n, 'status': 'running', 'running_in_app': true}
            else if (n['id'] == 'agent:b')
              {...n, 'status': 'idle', 'running_in_app': false}
            else
              n,
        ];
        final graph = <String, dynamic>{
          ...base,
          'nodes': nodes,
          'agent_badges': {
            'agent:a': {
              'kind': 'cost',
              'label': '80%',
              'colour': 'yellow',
              'tip': 'Limit',
            },
          },
          'usage_boxes': {
            'agent:a': {
              'model': 'claude',
              'parts': [
                [r'$1.20', 'green'],
              ],
            },
          },
          'activity': {
            'a': {
              'working': true,
              'active_subagents': 1,
              'subagents_supported': true,
              'children': [
                {'id': 'sub1'},
                {'id': 'sub2'},
              ],
            },
          },
          'traffic': {
            'a': {
              'connections': 3,
              'rate_in': 2048,
              'rate_out': 512,
              'received': 10240,
              'sent': 4096,
              'places': [
                {
                  'name': 'Anthropic API',
                  'kind': 'api',
                  'received': 8192,
                  'sent': 2048,
                  'connections': 2,
                },
              ],
              'programs': [
                {'name': 'claude', 'received': 8192, 'sent': 2048},
              ],
            },
          },
        };
        final subagents = <String>[], opened = <Map<String, dynamic>>[];
        tester.view.physicalSize = const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MapEditor(
                graph: graph,
                saved: const {},
                onEdit: (_) async {},
                tr: (s) => s,
                onSubagents: subagents.add,
                onOpen: opened.add,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        // Title shows limit badge and usage box.
        expect(find.byType(AgentBadge), findsOneWidget);
        expect(find.text('80%'), findsOneWidget);
        expect(find.byType(UsageBoxLabel), findsOneWidget);
        expect(find.text(r'$1.20'), findsOneWidget);

        // Subagents compact symbol + count shown on agent:a only.
        expect(find.byKey(const ValueKey('subagents-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('subagents-b')), findsNothing);
        expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('subagents-a')));
        await tester.pump();
        expect(subagents, ['a']);

        // Details symbol replaces open_in_new.
        expect(find.byIcon(Icons.open_in_new), findsNothing);
        expect(find.byIcon(Icons.info_outline), findsWidgets);
        await tester.tap(find.byKey(const ValueKey('details-agent:a')));
        await tester.pump();
        expect(opened.single['id'], 'agent:a');

        // Network traffic symbol shows current in/out rate in tooltip and opens dialog.
        expect(find.byKey(const ValueKey('traffic-a')), findsOneWidget);
        expect(find.byKey(const ValueKey('traffic-b')), findsNothing);
        expect(
          find.byTooltip(
            'Network: ↓ 2.0 KB/s ↑ 512 B/s. Click for its network statistics.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('traffic-a')));
        await tester.pumpAndSettle();
        expect(find.byType(AgentTrafficDialog), findsOneWidget);
        expect(find.text('In: 10.0 KB (2.0 KB/s)'), findsOneWidget);
        expect(find.text('Out: 4.0 KB (512 B/s)'), findsOneWidget);
        expect(
          find.text('Anthropic API · Online API · ↓ 8.0 KB ↑ 2.0 KB (2)'),
          findsOneWidget,
        );
        expect(find.text('claude · ↓ 8.0 KB ↑ 2.0 KB'), findsOneWidget);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('+ back to 100 % is a zoom, not a fit', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        edits: [],
        controller: controller,
        size: const Size(1000, 800),
      );
      await tester.pump();
      controller.value = Matrix4.diagonal3Values(.8, .8, 1);
      zoomMap(controller, 1.25);
      await tester.pump();
      await tester.pump();
      expect(controller.value.entry(0, 0), closeTo(1, .001));
    });

    testWidgets('the wheel scrolls, the buttons zoom', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        edits: [],
        controller: controller,
        size: const Size(1500, 500),
      );
      await tester.pump();
      expect(tester.getTopRight(find.byType(MapZoomControl)).dx, 1500 - 12);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      final middle = tester.getCenter(find.byType(InteractiveViewer));
      await tester.sendEventToBinding(mouse.hover(middle));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(controller.value.entry(0, 0), 1);
      expect(controller.value.getTranslation().y, -120); // it scrolled
      await tester.tap(find.byKey(const ValueKey('map-zoom-in')));
      await tester.pump();
      expect(controller.value.entry(0, 0), 1.25);
      await tester.tap(find.byKey(const ValueKey('map-zoom-fit')));
      await tester.pump();
      await tester.pump();
      expect(controller.value.entry(0, 0), 1);
    });

    testWidgets(
      'column cards align at 266 px with 12 px vertical gaps, and narrow bar neither overflows nor jumps the board',
      (tester) async {
        for (final smart in [false, true]) {
          tester.view.physicalSize = const Size(1500, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final g = fixtureGraph();
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: MapEditor(
                  graph: g,
                  saved: const {},
                  onEdit: (_) async {},
                  tr: (s) => s,
                  smartCards: smart,
                  groups: MapGroup.fromGraph(g, const [
                    'MCP servers and skills',
                    'Agents',
                    'Providers',
                    'Models',
                  ]),
                ),
              ),
            ),
          );
          await tester.pump();
          final groupCards = find.byType(MapGroupCard);
          expect(groupCards, findsNWidgets(4));
          for (var col = 0; col < 4; col++) {
            final groupPos = tester.widget<Positioned>(
              find
                  .ancestor(
                    of: groupCards.at(col),
                    matching: find.byType(Positioned),
                  )
                  .first,
            );
            expect(groupPos.left, 17.0 + col * 400);
            expect(groupPos.top, 8);
            expect(groupPos.width, 266);
            expect(groupPos.height, 86);
            expect(
              tester
                  .getSize(
                    find.descendant(
                      of: groupCards.at(col),
                      matching: find.byType(Card),
                    ),
                  )
                  .width,
              266,
            );
          }
          final agentsHeader = tester.widget<Positioned>(
            find
                .ancestor(
                  of: find.text('Online agents'),
                  matching: find.byType(Positioned),
                )
                .first,
          );
          expect(agentsHeader.left, 417);
          expect(agentsHeader.width, 266);
          if (smart) {
            final smartPos = tester.widget<Positioned>(
              find
                  .ancestor(
                    of: find.byKey(const ValueKey('smart-card-agents')),
                    matching: find.byType(Positioned),
                  )
                  .first,
            );
            expect(smartPos.left, 417);
            expect(smartPos.top, 106); // 8 + 86 + 12
            expect(smartPos.width, 266);
            expect(agentsHeader.top, 156); // 106 + 38 + 12
          } else {
            expect(agentsHeader.top, 106); // 8 + 86 + 12
          }
        }

        // Scroll is preserved when a column change refits without manual zoom,
        // and user zoom survives remounting (e.g. opening Settings and back)
        // while re-clamping when zoomed out or when content shrinks.
        final controller = TransformationController();
        addTearDown(controller.dispose);
        var showMap = true;
        var layers = const [
          'agents',
          'online',
          'local',
          'models',
          'mcp',
          'skills',
        ];
        late StateSetter rebuild;
        tester.view.physicalSize = const Size(1500, 500);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  if (!showMap) return const SizedBox.shrink();
                  return MapEditor(
                    graph: fixtureGraph(),
                    saved: const {},
                    onEdit: (_) async {},
                    tr: (s) => s,
                    controller: controller,
                    layers: layers,
                    onLayers: (next) => setState(() => layers = next),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();
        final mouse = TestPointer(2, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(
          mouse.hover(tester.getCenter(find.byType(InteractiveViewer))),
        );
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
        await tester.pump();
        expect(controller.value.getTranslation().y, -120);
        rebuild(
          () => layers = const ['agents', 'online', 'local', 'mcp', 'skills'],
        );
        await tester.pump();
        await tester.pump();
        expect(controller.value.getTranslation().y, -120);

        // User zooms to 125 %, opens another view (unmounts MapEditor), and
        // returns: the 125 % zoom stays until Fit / Ctrl+0 (including when
        // zoomMap is called while unmounted).
        zoomMap(controller, 1.25);
        await tester.pump();
        expect(controller.value.entry(0, 0), 1.25);
        rebuild(() => showMap = false);
        await tester.pump();
        rebuild(() => showMap = true);
        await tester.pump();
        await tester.pump();
        expect(controller.value.entry(0, 0), 1.25);
        rebuild(() => showMap = false);
        await tester.pump();
        zoomMap(controller, 0);
        rebuild(() => showMap = true);
        await tester.pump();
        await tester.pump();
        expect(controller.value.entry(0, 0), 1);
        zoomMap(controller, 1.25);
        await tester.pump();

        // When scrolled far down at high zoom, zooming out re-clamps y.
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 2000)));
        await tester.pump();
        final deepY = controller.value.getTranslation().y;
        zoomMap(controller, .5);
        await tester.pump();
        expect(controller.value.getTranslation().y, greaterThan(deepY));
        zoomMap(controller, 0);
        await tester.pump();
        await tester.pump();

        // At 500 px wide, starting a connection move shows Cancel + Disconnect
        // without overflowing or shifting the board vertically, and keeps
        // MapZoomControl inside the window at the right edge.
        tester.view.physicalSize = const Size(500, 700);
        await tester.pump();
        await tester.pump();
        final zoomRect = tester.getRect(find.byType(MapZoomControl));
        expect(zoomRect.left, greaterThanOrEqualTo(0));
        expect(zoomRect.right, 500 - 12);
        final boardTopBefore = tester
            .getTopLeft(find.byType(InteractiveViewer))
            .dy;
        await tester.tap(find.text('agent:a'));
        await tester.pumpAndSettle();
        final hook = find
            .byTooltip(
              'Move this connection to another compatible box, or to empty space to disconnect.',
            )
            .first;
        await tester.tap(hook);
        await tester.pump();
        expect(find.text('Cancel'), findsOneWidget);
        expect(find.text('Disconnect'), findsOneWidget);
        expect(tester.getRect(find.byType(MapZoomControl)).right, 500 - 12);
        expect(
          tester.getTopLeft(find.byType(InteractiveViewer)).dy,
          boardTopBefore,
        );
        expect(tester.takeException(), isNull);

        // Scrolling the mouse wheel over an open overflowing smart card
        // scrolls the card itself without scrolling the map underneath.
        await mount(
          tester,
          edits: [],
          smartCards: true,
          controller: controller,
          size: const Size(1500, 500),
        );
        await tester.pump();
        zoomMap(controller, 0);
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('smart-card-agents')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField),
          List.generate(20, (i) => 'line $i').join('\n'),
        );
        await tester.pump();
        final beforeScroll = controller.value.clone();
        final cardScroll = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const ValueKey('smart-card-agents')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        cardScroll.position.jumpTo(20);
        await tester.pump();
        await tester.sendEventToBinding(
          mouse.hover(tester.getCenter(find.byType(TextField))),
        );
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -10)));
        await tester.pump();
        expect(controller.value, beforeScroll);

        // Narrowing hides the Models smart card without closing or disposing it.
        var smartLayers = const [
          'agents',
          'online',
          'local',
          'models',
          'mcp',
          'skills',
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => MapEditor(
                  graph: fixtureGraph(),
                  saved: const {},
                  onEdit: (_) async {},
                  tr: (s) => s,
                  smartCards: true,
                  smartHelpers: const [
                    {
                      'command': 'local-helper',
                      'name': 'Local helper',
                      'local': true,
                    },
                  ],
                  layers: smartLayers,
                  onLayers: (next) => setState(() => smartLayers = next),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('smart-card-models')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'keep this prompt');
        await tester.pump();
        tester.view.physicalSize = const Size(1000, 700);
        await tester.pump();
        expect(find.byKey(const ValueKey('smart-card-models')), findsNothing);
        final hiddenModelsCard = find.byKey(
          const ValueKey('smart-card-models'),
          skipOffstage: false,
        );
        expect(tester.widget<MapSmartCard>(hiddenModelsCard).open, isTrue);
        expect(
          Focus.maybeOf(tester.element(hiddenModelsCard))?.canRequestFocus,
          isFalse,
        );
        // Moving to Models turns its column on in any window and opens it.
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .onMoveToColumn!('models', 'moved request');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<MapSmartCard>(
                find.byKey(const ValueKey('smart-card-models')),
              )
              .open,
          isTrue,
        );
        tester.view.physicalSize = const Size(1500, 700);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('smart-back')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('map-column-3')));
        await tester.pump();
        expect(find.byKey(const ValueKey('smart-card-models')), findsNothing);
        tester
            .widget<MapSmartCard>(
              find.byKey(const ValueKey('smart-card-agents')),
            )
            .onMoveToColumn!('models', 'keep this prompt');
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<MapSmartCard>(
                find.byKey(const ValueKey('smart-card-models')),
              )
              .open,
          isTrue,
        );
        expect(find.text('keep this prompt'), findsOneWidget);

        // AgentMap (System Map path) saves the post-scroll and post-zoom
        // transform via onViewChanged and re-clamps when zooming out.
        final sysController = TransformationController();
        addTearDown(sysController.dispose);
        final savedMatrices = <Matrix4>[];
        tester.view.physicalSize = const Size(660, 500);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AgentMap(
                graph: fixtureGraph(),
                onAgent: (_) {},
                tr: (s) => s,
                controller: sysController,
                onViewChanged: () =>
                    savedMatrices.add(sysController.value.clone()),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.sendEventToBinding(
          mouse.hover(tester.getCenter(find.byType(InteractiveViewer))),
        );
        await tester.sendEventToBinding(mouse.scroll(const Offset(800, 0)));
        await tester.pump();
        expect(sysController.value.getTranslation().x, lessThan(-500));
        expect(savedMatrices.last, sysController.value);
        savedMatrices.clear();
        zoomMap(sysController, .3);
        await tester.pump();
        expect(sysController.value.getTranslation().x, 0);
        expect(savedMatrices.last, sysController.value);
      },
    );

    testWidgets(
      'smart card status symbol opens column status list, Ask AI switches to prompt, and no-helper state shows Get started',
      (tester) async {
        final actions = <List<String>>[];
        final status = SmartStatusData(
          report: const {
            'warn': 1,
            'hint': 1,
            'areas': [
              {
                'key': 'agents',
                'title': 'Agents',
                'findings': [
                  {
                    'level': 'warn',
                    'column': 'agents',
                    'title': 'Pi: Not signed in',
                    'text': 'Sign in: pi login',
                    'action': ['details', 'pi'],
                  },
                ],
              },
              {
                'key': 'local',
                'title': 'Local LLMs',
                'findings': [
                  {
                    'level': 'hint',
                    'column': 'models',
                    'title': 'llama.cpp has no models yet',
                    'text': 'Download a model.',
                    'action': ['models', 'llamacpp'],
                  },
                ],
              },
            ],
            'uses': [],
          },
          onAction: actions.add,
        );
        await mount(
          tester,
          edits: [],
          smartCards: true,
          smartHelpers: const [],
          smartStatus: status,
        );
        await tester.pump();

        // Clicking the status symbol on Agents opens the card on its status list.
        await tester.tap(find.byKey(const ValueKey('smart-status-agents')));
        await tester.pumpAndSettle();
        expect(find.text('Pi: Not signed in'), findsOneWidget);
        expect(find.text('llama.cpp has no models yet'), findsNothing);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Details'));
        await tester.pump();
        expect(actions.single, ['details', 'pi']);

        // Re-open Agents on status and click Ask AI on the finding: switches to prompt.
        await tester.tap(find.byKey(const ValueKey('smart-status-agents')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('smart-ask-finding-Pi: Not signed in')),
        );
        await tester.pumpAndSettle();
        expect(find.text('No AI helper is set up yet.'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.widgetWithText(OutlinedButton, 'Get started'));
        await tester.pump();
        expect(actions.last, ['firstagent']);

        // Clicking the status symbol on MCP (no open items) shows the one-line Nothing to fix.
        await tester.tap(find.byKey(const ValueKey('smart-status-mcp')));
        await tester.pumpAndSettle();
        expect(find.text('Nothing to fix.'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('smart-status-ask')));
        await tester.pumpAndSettle();
        expect(find.text('No AI helper is set up yet.'), findsOneWidget);
      },
    );
  });
}
