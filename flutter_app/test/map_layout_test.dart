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
      expect(wide.columnGap, 228);
      expect(wide.columnWidth, 295);
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
        const Rect.fromLTWH(16, 106, 266, 32 + 146),
      );
      expect(
        l.cards['1:agent:']!.rect,
        const Rect.fromLTWH(318, 106, 266, 32 + 2 * 146),
      );
      expect(l.boxes['mcp:c']!.left - l.cards['0:mcp:']!.rect.left, 12);
      expect(l.cards['0:mcp:']!.rect.right - l.boxes['mcp:c']!.right, 12);
      expect(l.cards['0:mcp:']!.rect.bottom - l.boxes['mcp:c']!.bottom, 12);
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

  test('two columns use the whole of a wide window', () {
    final l = MapLayout(
      fixtureGraph(),
      {},
      columns: const [0, 1],
      viewportWidth: 1896,
    );
    expect(l.columnWidth, 360);
    expect(l.columnGap, greaterThan(400));
    expect(l.size.width, greaterThan(1650));
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
}
