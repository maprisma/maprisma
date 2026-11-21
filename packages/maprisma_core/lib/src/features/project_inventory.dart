import '../inventory.dart' show chatModels;
import '../provider_scans.dart' show RuntimeRecord, localRuntime;

const maxRuntimeModels = 48;

/// The same detected runtime/connection relation as the map, without addresses
/// or provider configuration. Ambiguous aliases need an explicit map change.
List<Map<String, dynamic>> projectRuntimeFacts(
  List<RuntimeRecord> runtimes,
  List<Map<String, dynamic>> agents,
) {
  final bindings = <String, Map<String, dynamic>>{};
  for (final agent in agents) {
    final choices = (agent['models'] as List).cast<String>();
    for (final provider in (agent['providers'] as List).cast<Map>()) {
      final rt = localRuntime(provider, runtimes);
      if (rt == null) continue;
      final id = provider['id'] ?? provider['name'];
      final prefix = '$id/';
      // The same bound as the runtime's offered list, so every model a
      // binding offers also passes the launch check.
      final served = chatModels(rt.models).take(maxRuntimeModels).toSet();
      final models = [
        for (final choice in choices)
          if (choice.startsWith(prefix) &&
              served.contains(choice.substring(prefix.length)))
            choice.substring(prefix.length),
      ];
      final perRuntime = bindings.putIfAbsent(rt.key, () => {});
      if (perRuntime.containsKey(agent['id'])) {
        perRuntime[agent['id']] = null;
      } else {
        perRuntime[agent['id'] as String] = {'provider': id, 'models': models};
      }
    }
  }
  return [
    for (final rt in runtimes)
      {
        'key': rt.key,
        'name': rt.name,
        'aliases': {
          rt.key,
          rt.name,
          if (rt.name.contains('.')) rt.name.split('.').first,
        }.toList(),
        'installed': rt.installed,
        'running': rt.running && !rt.serverOff,
        'models': chatModels(rt.models).take(maxRuntimeModels).toList(),
        'bindings': {
          for (final entry in (bindings[rt.key] ?? {}).entries)
            if (entry.value != null) entry.key: entry.value,
        },
      },
  ];
}
