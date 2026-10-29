import 'adapter_assets.g.dart';

/// Providers a verified add-on brings: the built-in ones are hidden
/// (providers.hide_built_in); the loaded add-ons' come after the visible
/// built-in ones, in the order they were added (providers._ADDED).
final hiddenProviders = <String>{};
final addedProviders = <String>[];

Map<String, dynamic>? _cached;
String _cachedFor = '';

/// providerFacts as the app sees them now: local providers, their connect
/// keys and labels, the online providers and what they name, without the
/// hidden ones (providers.local / online / connect_keys / cloud_of_agent /
/// online_names).
Map<String, dynamic> get visibleProviderFacts {
  final key =
      '${(hiddenProviders.toList()..sort()).join(',')}|${addedProviders.join(',')}';
  if (_cached != null && key == _cachedFor) return _cached!;
  List<Map> visible(String name) {
    final all = (providerFacts[name] as List).cast<Map>();
    final added = [
      for (final key in addedProviders) ...all.where((p) => p['key'] == key),
    ];
    if (name == 'local') {
      // providers.local: added local LLMs in the built-in order (LOCAL_ORDER).
      final order = [for (final p in all) p['key']];
      final indexed = [for (var i = 0; i < added.length; i++) (i, added[i])]
        ..sort((a, b) {
          final c = order
              .indexOf(a.$2['key'])
              .compareTo(order.indexOf(b.$2['key']));
          return c != 0 ? c : a.$1.compareTo(b.$1);
        });
      added
        ..clear()
        ..addAll(indexed.map((e) => e.$2));
    }
    return [...all.where((p) => !hiddenProviders.contains(p['key'])), ...added];
  }

  final local = visible('local');
  final keys = {for (final p in local) p['key']};
  Map<String, dynamic> only(String name) => {
    for (final e in (providerFacts[name] as Map).entries)
      if (keys.contains(e.key)) e.key as String: e.value,
  };
  final online = visible('online_providers');
  _cached = {
    ...providerFacts,
    'local': local,
    'connect_keys': only('connect_keys'),
    'connect_labels': only('connect_labels'),
    'online': [
      for (final p in online) {'key': p['key'], 'name': p['name']},
    ],
    'cloud': {
      for (final p in online)
        for (final agent in p['agents'] as List) agent as String: p['name'],
    },
    'names': {
      for (final p in online)
        for (final id in p['ids'] as List) id as String: p['name'],
    },
  };
  _cachedFor = key;
  return _cached!;
}

/// Every provider key the app has built in (local and online).
List<String> providerFactsAll() => [
  for (final p in (providerFacts['local'] as List).cast<Map>())
    p['key'] as String,
  for (final p in (providerFacts['online_providers'] as List).cast<Map>())
    p['key'] as String,
];
