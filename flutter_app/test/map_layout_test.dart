import 'dart:ui';

import 'package:maprisma/map_layout.dart';
import 'package:flutter/material.dart' show ColorScheme, HSLColor;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> fixtureGraph({bool active = false}) => {
  'nodes': [
    for (final (id, kind, col) in [
      ('agent:a', 'agent', 1),
      ('agent:b', 'agent', 1),
      ('runtime:r', 'runtime', 2),
      ('runtime:s', 'runtime', 2),
      ('model:r:m', 'model', 3),
      ('model:r:n', 'model', 3),
      ('mcp:c', 'mcp', 0),
    ])
      {'id': id, 'kind': kind, 'column': col, 'label': id, 'detail': ''},
  ],
  'edges': [
    {
      'source': 'agent:a',
      'target': 'runtime:r',
      'kind': 'uses',
      'active': active,
      'activity': 'agent',
    },
    {
      'source': 'runtime:r',
      'target': 'model:r:m',
      'kind': 'serves',
      'active': active,
      'activity': 'agent',
    },
    {'source': 'runtime:r', 'target': 'model:r:n', 'kind': 'serves'},
    {'source': 'agent:a', 'target': 'model:r:m', 'kind': 'default'},
  ],
};
void main() {
  test('a card set to used only leaves out boxes without a line or a pin', () {
    final graph = {
      ...fixtureGraph(),
      'nodes': [
        ...fixtureGraph()['nodes'] as List,
        {'id': 'mcp:d', 'kind': 'mcp', 'column': 0, 'label': 'd', 'detail': ''},
      ],
    };
    final all = MapLayout(graph, {});
    final card = all.cardOf['mcp:c']!;
    expect(all.boxes.containsKey('mcp:c'), isTrue);
    final used = MapLayout(graph, {
      'used_only': [card, all.cardOf['agent:a']!],
      'pins': ['mcp:d'],
    });
    expect(used.boxes.containsKey('mcp:c'), isFalse, reason: 'no line, no pin');
    expect(used.boxes.containsKey('mcp:d'), isTrue, reason: 'pinned');
    expect(used.boxes.containsKey('agent:a'), isTrue);
    expect(used.boxes.containsKey('agent:b'), isFalse);
    // A model only present in its provider's folder is no connection.
    final models = MapLayout(fixtureGraph(), {
      'used_only': [MapLayout(fixtureGraph(), {}).cardOf['model:r:n']!],
    });
    expect(models.boxes.containsKey('model:r:m'), isTrue, reason: 'in use');
    expect(models.boxes.containsKey('model:r:n'), isFalse, reason: 'unused');
  });

  test('with borders: hooks where the line shows, no clicks in a card', () {
    final bordered = MapLayout(fixtureGraph(), {
      'card_border': {'on': true},
    });
    for (final curve in bordered.curves) {
      expect(bordered.insideCard(bordered.hookOf(curve)), isFalse);
    }
    final card = bordered.cards.values.first.rect;
    expect(bordered.lineAt(card.center), isNull);
  });

  test('used only: an empty card fits its header, order keeps the hidden', () {
    final all = MapLayout(fixtureGraph(), {});
    final mcp = all.cardOf['mcp:c']!, agents = all.cardOf['agent:a']!;
    final used = MapLayout(fixtureGraph(), {
      'used_only': [mcp, agents],
      'order': {
        agents: ['agent:b', 'agent:a'],
      },
    });
    expect(used.cards[mcp]!.rect.height, 38);
    final saved = reorderMapBox({}, used, 'agent:a', 0);
    expect((saved['order'] as Map)[agents], ['agent:b', 'agent:a']);
  });

  test('programs to install end the online agents card, unless folded', () {
    final graph = {
      ...fixtureGraph(),
      'missing': [
        {'command': 'codex', 'name': 'Codex', 'addon': 'agent-codex'},
        {'command': 'goose', 'name': 'Goose', 'addon': 'agent-goose'},
      ],
    };
    final plain = MapLayout(fixtureGraph(), {}).cards['1:agent:']!;
    final l = MapLayout(graph, {});
    final card = l.cards['1:agent:']!;
    expect(card.missing.map((m) => m.$2['command']), ['codex', 'goose']);
    expect(card.rect.height, plain.rect.height + 2 * mapAddStep);
    final first = card.missing.first.$1, last = card.missing.last.$1;
    expect(first.top - l.boxes['agent:b']!.bottom, 12);
    expect(last.top - first.top, mapAddStep);
    expect(card.rect.bottom - last.bottom, 12);
    expect(first.left, l.boxes['agent:b']!.left);
    expect(first.width, l.boxes['agent:b']!.width);
    // Other cards have none; a new one is a new layout.
    expect(l.cards['0:mcp:']!.missing, isEmpty);
    expect(l.updateGraph(fixtureGraph()), false);
    expect(
      MapLayout(graph, {
        'collapsed': ['1:agent:'],
      }).cards['1:agent:']!.missing,
      isEmpty,
    );
    // Just switched on: they show in a card set to only what is connected.
    expect(
      MapLayout(graph, {
        'used_only': ['1:agent:'],
      }).cards['1:agent:']!.missing.length,
      2,
    );
  });

  test('agents made for a local LLM get a card of their own, below the online '
      'ones; programs to install go to the online card', () {
    final base = fixtureGraph();
    final graph = {
      ...base,
      'nodes': [
        for (final n in base['nodes'] as List<Map<String, dynamic>>)
          n['id'] == 'agent:a' ? {...n, 'group': 'local'} : n,
      ],
      'missing': [
        {'command': 'codex', 'name': 'Codex', 'addon': 'agent-codex'},
      ],
    };
    final l = MapLayout(graph, {});
    final online = l.cards['1:agent:']!, local = l.cards['1:agent:local']!;
    expect(online.nodes, ['agent:b']);
    expect(local.nodes, ['agent:a']);
    expect(online.label, 'Online agents');
    expect(local.label, 'Local agents');
    expect(local.rect.top, greaterThan(online.rect.bottom));
    expect(online.missing.map((m) => m.$2['command']), ['codex']);
    expect(local.missing, isEmpty);
    // Moved by hand: the saved order wins.
    final moved = MapLayout(graph, {
      'card_order': ['1:agent:local', '1:agent:'],
    });
    expect(
      moved.cards['1:agent:local']!.rect.top,
      lessThan(moved.cards['1:agent:']!.rect.top),
    );
    // Only local agents: programs to install end their card.
    final onlyLocal = {
      ...graph,
      'nodes': [
        for (final n in graph['nodes'] as List<Map<String, dynamic>>)
          if (n['kind'] == 'agent') {...n, 'group': 'local'} else n,
      ],
    };
    expect(MapLayout(onlyLocal, {}).cards['1:agent:local']!.missing.length, 1);
  });

  test('a local LLM to install ends the local providers card', () {
    final graph = {
      ...fixtureGraph(),
      'missing': [
        {
          'command': 'vllm',
          'name': 'vLLM',
          'addon': 'llm-vllm',
          'kind': 'runtime',
        },
      ],
    };
    final l = MapLayout(graph, {});
    final card = l.cards['2:runtime:']!;
    expect(card.missing.map((m) => m.$2['command']), ['vllm']);
    expect(card.missing.single.$1.top - l.boxes['runtime:s']!.bottom, 12);
    expect(l.cards['1:agent:']!.missing, isEmpty);
  });

  test('a box just switched on shows in a card set to used only', () {
    final saved = {
      'used_only': [MapLayout(fixtureGraph(), {}).cardOf['runtime:s']!],
    };
    expect(
      MapLayout(fixtureGraph(), saved).boxes,
      isNot(contains('runtime:s')),
    );
    final l = MapLayout({
      ...fixtureGraph(),
      'fresh': ['runtime:s', 'agent:nothing'],
    }, saved);
    expect(l.boxes, contains('runtime:s'));
    expect(l.updateGraph(fixtureGraph()), false);
  });
  test('a colour is a hex value or one of the theme', () {
    final colors = ColorScheme.fromSeed(seedColor: const Color(0xff123456));
    expect(mapColor('theme:tertiary', colors), colors.tertiary);
    expect(mapColor('#ff0000', colors), const Color(0xffff0000));
    expect(mapColor('theme:pink', colors), isNull);
    expect(mapLineKind('available'), 'provider');
    expect(mapLineKind('offer'), isNull);
  });

  test('a column keeps its own width; the next one moves along', () {
    final auto = MapLayout(
      const {'nodes': [], 'edges': []},
      const {},
      viewportWidth: 1896,
    );
    final set = MapLayout(
      const {'nodes': [], 'edges': []},
      const {
        'column_widths': {'agents': 500},
        'column_defaults': {'agents': 300, 'models': 320},
      },
      viewportWidth: 1896,
    );
    expect(set.columnWidthOf(1), 500);
    expect(set.columnWidthOf(3), 320);
    expect(set.columnWidthOf(0), auto.columnWidthOf(0));
    expect(set.columnX(2), set.columnX(1) + 500 + set.columnGap);
  });

  test(
    'a wide window gives the lines room; the columns never go below 266',
    () {
      final wide = MapLayout(
        const {'nodes': [], 'edges': []},
        const {},
        viewportWidth: 1896,
      );
      expect(wide.columnWidth, 295);
      // Four columns share what is left evenly: the same gap at both edges
      // and between the columns.
      expect(wide.columnGap, 143);
      expect(wide.columnX(0), closeTo(143, 2));
      expect(
        1896 - (wide.columnX(3) + wide.columnWidth),
        closeTo(wide.columnGap, 2),
      );
      final tight = MapLayout(
        const {'nodes': [], 'edges': []},
        const {},
        viewportWidth: 1300,
      );
      expect(tight.columnWidth, greaterThanOrEqualTo(266));
      expect(tight.columnX(3) + tight.columnWidth, lessThanOrEqualTo(1300));
    },
  );

  test('bezier distance, node and hook hit testing use scene coordinates', () {
    final l = MapLayout(fixtureGraph(), {});
    final curve = l.curves.first;
    expect(curve.distance(curve.point(.45)), lessThan(1));
    expect(l.lineAt(curve.point(.45)), curve);
    expect(l.lineAt(const Offset(20, 30)), isNull);
    expect(l.hookAt(curve.hook, {'agent:a'}), curve);
    expect(l.hookAt(curve.hook, {}), isNull);
    expect(l.nodeAt(l.boxes['agent:a']!.center), 'agent:a');
  });
  test('agent → provider → model: one line each; unused models have none', () {
    final layout = MapLayout(fixtureGraph(), {});
    expect(
      layout.allEdges.where((edge) => edge['kind'] == 'serves'),
      hasLength(2),
    );
    // model:r:m is agent:a's model through runtime:r; model:r:n is unused.
    expect(
      [
        for (final c in layout.curves)
          '${c.edge['source']} ${c.edge['kind']} ${c.edge['target']}',
      ],
      unorderedEquals(['agent:a uses runtime:r', 'runtime:r serves model:r:m']),
    );
    expect(layout.modelsInUse, {'model:r:m'});
    // The hidden agent → model line is not offered for moving; the provider's
    // line is.
    final hidden = layout.allEdges.firstWhere((e) => e['kind'] == 'default');
    expect(layout.viaProvider(hidden), isTrue);
    expect(layout.movable(hidden), isFalse);
    // An offer (a model the agent could pick online) is not drawn.
    final offered = MapLayout({
      ...fixtureGraph(),
      'edges': [
        ...fixtureGraph()['edges'] as List,
        {'source': 'agent:b', 'target': 'runtime:s', 'kind': 'offer'},
      ],
    }, {});
    expect(offered.curves.where((c) => c.edge['kind'] == 'offer'), isEmpty);
    // A provider's own choice of model: its line shows without any agent, it
    // counts for the filter, and a choice the provider does not serve shows
    // nothing.
    final chosen = MapLayout(
      {
        ...fixtureGraph(),
        'provider_models': {'runtime:r': 'model:r:n', 'runtime:s': 'model:r:m'},
      },
      {
        'used_only': [MapLayout(fixtureGraph(), {}).cardOf['model:r:n']!],
      },
    );
    expect(chosen.chosenModels, {'model:r:n'});
    expect(
      chosen.curves.where(
        (c) =>
            c.edge['source'] == 'runtime:r' && c.edge['target'] == 'model:r:n',
      ),
      hasLength(1),
    );
    expect(
      chosen.curves.where((c) => c.edge['source'] == 'runtime:s'),
      isEmpty,
    );
    expect(chosen.boxes.containsKey('model:r:n'), isTrue);
    expect(layout.movable(layout.curves.last.edge), isTrue);
    expect(layout.providerFor('model:r:m'), 'runtime:r');
    expect(layout.targetOk('agent:a', 'model:r:n'), true);
  });
  test('collaboration lines never take the error colour', () {
    double apart(Color a, Color b) {
      final d = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs();
      return d > 180 ? 360 - d : d;
    }

    // Tokyo Night, Catppuccin, Kanagawa (blue), Material purple, Gruvbox.
    for (final primary in const [
      Color(0xFF7AA2F7),
      Color(0xFF89B4FA),
      Color(0xFF7E9CD8),
      Color(0xFF6750A4),
      Color(0xFFD79921),
    ]) {
      for (final brightness in Brightness.values) {
        final colors = ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(primary: primary);
        final collab = mapCollaborationColor(colors);
        expect(apart(collab, colors.error), greaterThanOrEqualTo(45));
        expect(apart(collab, primary), greaterThanOrEqualTo(45));
      }
    }
  });
  test('folding does not change connection semantics', () {
    final l = MapLayout(fixtureGraph(), {
      'collapsed': ['2:runtime:'],
    });
    expect(l.boxes.containsKey('runtime:r'), false);
    expect(l.providerFor('model:r:m'), 'runtime:r');
    expect(l.targetOk('agent:a', 'model:r:n'), true);
    expect(l.targetOk('agent:b', 'model:r:n'), false);
  });
  test(
    'drag targets reject self, unsupported kinds and other provider models',
    () {
      final l = MapLayout(fixtureGraph(), {});
      expect(l.targetOk('agent:a', 'mcp:c'), true);
      expect(l.targetOk('mcp:c', 'agent:a'), true);
      expect(l.targetOk('agent:a', 'agent:a'), false);
      expect(l.targetOk('runtime:s', 'model:r:m'), false);
      expect(
        l.targetOk('agent:a', 'runtime:s', moving: l.curves.first.edge),
        true,
      );
      expect(
        l.targetOk('agent:a', 'mcp:c', moving: l.curves.first.edge),
        false,
      );
    },
  );
  test(
    'saved layout retains folds and column order, and ignores old free card positions',
    () {
      final graph = {
        ...fixtureGraph(),
        'nodes': [
          ...(fixtureGraph()['nodes'] as List),
          {
            'id': 'skills:s',
            'kind': 'skills',
            'column': 0,
            'label': 'skills:s',
            'detail': '',
          },
        ],
      };
      final l = MapLayout(graph, {
        'cards': {
          '0:mcp:': [500, 300],
          '1:agent:': [40, 300],
        },
      });
      // Old free card coordinates in `cards` are ignored; cards stay in their column.
      expect(
        l.cards['0:mcp:']!.rect,
        // The MCP card ends with its add card.
        const Rect.fromLTWH(16, 106, 266, 32 + 146 + mapAddStep),
      );
      expect(
        l.cards['1:agent:']!.rect,
        const Rect.fromLTWH(318, 106, 266, 32 + 2 * 146),
      );
      expect(l.boxes['mcp:c']!.left - l.cards['0:mcp:']!.rect.left, 12);
      expect(l.cards['0:mcp:']!.rect.right - l.boxes['mcp:c']!.right, 12);
      final add = l.cards['0:mcp:']!.add!;
      expect(add.top - l.boxes['mcp:c']!.bottom, 12);
      expect(l.cards['0:mcp:']!.rect.bottom - add.bottom, 12);
      expect(add.left, l.boxes['mcp:c']!.left);
      expect(add.width, l.boxes['mcp:c']!.width);
      expect(l.cards['1:agent:']!.rect.bottom - l.boxes['agent:b']!.bottom, 12);
      expect(
        MapLayout(graph, {
          'collapsed': ['0:mcp:'],
        }).cards['0:mcp:']!.rect.height,
        38,
      );
      final saved = reorderMapBox(
        l.cards.isEmpty ? {} : {'cards': {}},
        l,
        'agent:b',
        0,
      );
      expect(MapLayout(graph, saved).cards['1:agent:']!.nodes.first, 'agent:b');
      final reordered = reorderMapCard(saved, l, '0:mcp:', 1);
      expect(reordered.containsKey('cards'), false);
      final after = MapLayout(graph, reordered);
      final col0 = [
        for (final c in after.cards.values)
          if (c.column == 0) c.id,
      ];
      expect(col0, ['0:skills:', '0:mcp:']);
      expect(after.cards['0:skills:']!.rect.left, 16);
      expect(after.cards['0:mcp:']!.rect.left, 16);
      expect(
        MapLayout(graph, {}, smartCards: true).cards['1:agent:']!.rect.top,
        156,
      );
      expect((fixtureGraph()['nodes'] as List).length, 7);
    },
  );

  Map<String, dynamic> twoColumns() {
    final graph = fixtureGraph();
    final nodes = [
      for (final n in graph['nodes'] as List)
        if ((n as Map)['column'] == 1 || n['column'] == 2) n,
    ];
    final ids = {for (final n in nodes) n['id']};
    return {
      ...graph,
      'nodes': nodes,
      'edges': [
        for (final e in graph['edges'] as List)
          if (ids.contains((e as Map)['source']) && ids.contains(e['target']))
            e,
      ],
    };
  }

  test('a hidden column keeps its card order', () {
    final graph = twoColumns();
    final saved = {
      'card_order': ['3:model:', '0:mcp:'],
    };
    final shown = MapLayout(graph, saved, columns: const [1, 2]);
    final id = shown.cards.keys.first;
    final next = reorderMapCard(saved, shown, id, 0);
    expect(next['card_order'], containsAll(['3:model:', '0:mcp:', id]));
  });

  test('a wide window: the same gap left, between and right', () {
    for (final columns in const [
      [0, 1],
      [1, 2, 3],
    ]) {
      final l = MapLayout(
        fixtureGraph(),
        {},
        columns: columns,
        viewportWidth: 1896,
      );
      expect(l.columnWidth, 360);
      final left = l.columnX(columns.first),
          right = 1896 - (l.columnX(columns.last) + l.columnWidth),
          between = l.columnX(columns[1]) - (left + l.columnWidth);
      expect(left, closeTo(l.columnGap, 2));
      expect(right, closeTo(l.columnGap, 2));
      expect(between, l.columnGap);
      expect(l.columnGap, greaterThan(200));
    }
  });

  test('the shown columns sit in the middle of the window', () {
    final l = MapLayout(
      twoColumns(),
      const {},
      columns: const [1, 2],
      viewportWidth: 1000,
    );
    final left = l.columnX(1), right = 1000 - (l.columnX(2) + l.columnWidth);
    expect(left, closeTo(right, 2));
    expect(l.columnWidth, inInclusiveRange(266, 360));
    expect(l.columnGap, greaterThanOrEqualTo(36));
    expect(l.boxes['agent:a']!.width, l.columnWidth - 24);
    expect(l.size.width, lessThanOrEqualTo(1000));

    final empty = MapLayout(
      const {'nodes': [], 'edges': []},
      const {},
      columns: const [0, 1, 2, 3],
      viewportWidth: 1500,
    );
    expect(
      empty.size.width,
      greaterThanOrEqualTo(empty.columnX(3) + empty.columnWidth + 16),
    );
    expect(empty.size.width, lessThanOrEqualTo(1500));
  });

  test('MCP, skills and local model folder cards end with an add card', () {
    final graph = {
      ...fixtureGraph(),
      'nodes': [
        ...(fixtureGraph()['nodes'] as List),
        {
          'id': 'skills:s',
          'kind': 'skills',
          'column': 0,
          'label': 'skills:s',
          'detail': '',
        },
        {
          'id': 'model:cloud:x:y',
          'kind': 'model',
          'column': 3,
          'label': 'y',
          'detail': '',
          'group': 'online',
        },
      ],
      'edges': [
        ...(fixtureGraph()['edges'] as List),
        {'source': 'cloud:x', 'target': 'model:cloud:x:y', 'kind': 'serves'},
      ],
    };
    final l = MapLayout(graph, const {});
    expect(
      [
        for (final c in l.cards.values)
          if (c.add != null) (c.id, c.addKind, c.addTarget),
      ],
      unorderedEquals([
        ('0:mcp:', 'mcp', ''),
        ('0:skills:', 'skills', ''),
        // The folder a local LLM serves: its download is for that one.
        ('3:model:', 'model', 'r'),
      ]),
    );
    // An online provider's models are not downloaded: no add card.
    expect(l.cards['3:model:online']!.add, isNull);
    expect(l.cards['1:agent:']!.add, isNull);
    // Folded: neither the add card nor its room.
    final folded = MapLayout(graph, const {
      'collapsed': ['3:model:'],
    });
    expect(folded.cards['3:model:']!.add, isNull);
    expect(folded.cards['3:model:']!.rect.height, 38);
  });
  test('an online provider takes only its own agent (review 063 F1)', () {
    final graph = fixtureGraph();
    final nodes = [
      for (final n in graph['nodes'] as List) Map<String, dynamic>.from(n),
    ];
    graph['nodes'] = nodes;
    nodes.firstWhere((n) => n['id'] == 'agent:a')['own_provider'] =
        'cloud:openai';
    nodes.addAll([
      for (final id in ['cloud:openai', 'cloud:google'])
        {'id': id, 'kind': 'cloud', 'column': 2, 'label': id, 'detail': ''},
    ]);
    final l = MapLayout(graph, {});
    expect(l.targetOk('agent:a', 'cloud:openai'), isTrue);
    expect(l.targetOk('cloud:openai', 'agent:a'), isTrue);
    expect(l.targetOk('agent:a', 'cloud:google'), isFalse);
    expect(l.targetOk('cloud:google', 'agent:a'), isFalse);
    expect(l.targetOk('agent:b', 'cloud:openai'), isFalse);
  });
}
