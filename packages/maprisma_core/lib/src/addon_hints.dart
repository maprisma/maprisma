import 'dart:io';
import 'package:path/path.dart' as p;
import 'desktop.dart' show whichIn;

/// Add-on suggestions and updates (ai_popup.look_for_addons and its hint
/// lines in overview_hints): agents and local LLMs on this PC whose add-on is
/// off or not installed yet, and installed add-ons the signed catalog has a
/// newer version of.

/// addon_store.present: the detect hints of a catalog entry find its program
/// on PATH or its folder (read-only checks).
bool addonPresent(Map entry, String home, String? searchPath) {
  for (final c in entry['commands'] as List? ?? const []) {
    if (c is String && whichIn(c, searchPath) != null) return true;
  }
  for (final x in entry['paths'] as List? ?? const []) {
    if (x is String &&
        x.startsWith('~/') &&
        FileSystemEntity.typeSync(p.join(home, x.substring(2))) !=
            FileSystemEntityType.notFound) {
      return true;
    }
  }
  return false;
}

String _listed(List<String> names, int most) =>
    names.take(most).join(', ') + (names.length > most ? '…' : '');

/// The hint lines: `off` (its add-on is installed but switched off), `new`
/// (not installed yet), `updates` (with the catalog previews to install).
/// rows: the catalog's public rows (with `present`); states: installed
/// add-on id → its state.
List<Map<String, dynamic>> addonHints(
  List<Map<String, dynamic>> rows,
  Map<String, String> states,
  String Function(String) tr,
  String Function(String one, String other, int n) plural,
) {
  final waiting = {'off': <Map>[], 'new': <Map>[]};
  for (final row in rows) {
    if (row['present'] != true ||
        !const {'agent', 'provider'}.contains(row['kind'])) {
      continue;
    }
    final state = states[row['id']];
    if (state == null) {
      waiting['new']!.add(row);
    } else if (state == 'verified') {
      waiting['off']!.add(row);
    }
  }
  final lines = <Map<String, dynamic>>[];
  for (final e in waiting.entries) {
    if (e.value.isEmpty) continue;
    final names = [for (final r in e.value) '${r['name']}'];
    lines.add({
      'kind': e.key,
      'text':
          plural(
                '{0} is on this PC but not on the map',
                '{1} are on this PC but not on the map',
                names.length,
              )
              .replaceAll('{0}', _listed(names, 1))
              .replaceAll('{1}', _listed(names, 3)),
      'ids': [for (final r in e.value) r['id']],
      'column': e.value.first['kind'] == 'agent' ? 'agents' : 'providers',
    });
  }
  final updates = [
    for (final r in rows)
      if (r['action'] == 'update' && r['preview'] is String) r,
  ];
  // Each column offers the updates of its own add-ons.
  for (final (column, isProvider) in const [
    ('agents', false),
    ('providers', true),
  ]) {
    final own = [
      for (final r in updates)
        if ((r['kind'] == 'provider') == isProvider) r,
    ];
    if (own.isEmpty) continue;
    lines.add({
      'kind': 'updates',
      'column': column,
      'text': tr(
        'Add-on updates ready: {0}',
      ).replaceAll('{0}', _listed([for (final r in own) '${r['name']}'], 3)),
      'updates': [
        for (final r in own)
          {
            'id': r['id'],
            'name': r['name'],
            'version': r['version'],
            'current': r['installed_version'],
            'preview': r['preview'],
          },
      ],
    });
  }
  return lines;
}
