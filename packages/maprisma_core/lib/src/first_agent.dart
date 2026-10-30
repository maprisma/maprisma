import 'dart:convert';
import 'dart:io';
import 'adapters.dart';
import 'addons.dart';
import 'agent_catalog.dart';
import 'core_assets.g.dart' show firstAgentCatalogText;
import 'desktop.dart' show whichIn;
import 'installers.dart' show Installers;
import 'local_llm.dart';
import 'provider_facts.dart';
import 'provider_scans.dart';
import 'py_values.dart' show pyFixedExact, pyTruthy;
import 'scan_files.dart';

/// first_agent: the routes to a first working agent (data/first-agent.json,
/// or a loaded add-on's copy), checked when read.
final class FirstAgentRoute {
  FirstAgentRoute(
    this.id,
    this.kind,
    this.agent,
    this.title,
    this.access,
    this.runtime,
    this.needs,
    this.name,
  );
  final String id, kind, agent, title, access, runtime, name;
  final List<String> needs;
}

final _id = RegExp(r'^[a-z0-9][a-z0-9.-]{0,47}$');
final _key = RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$');
final _pricing = RegExp(r'^https://[A-Za-z0-9./_-]{1,200}$');
const _maxCatalog = 256 * 1024;

/// first_agent._text: words joined by one space, cut.
String _text(dynamic value, int most) {
  if (value is! String) return '';
  final joined = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ');
  final runes = joined.runes.toList();
  return runes.length > most ? String.fromCharCodes(runes.take(most)) : joined;
}

/// first_agent.parse (the routes; the starter models are the Models page's).
List<FirstAgentRoute> parseRoutes(dynamic data) {
  final routes = <FirstAgentRoute>[];
  if (data is! Map) return routes;
  final items = pyTruthy(data['routes']) ? data['routes'] : const [];
  for (final item in items is List ? items : const []) {
    if (item is! Map) continue;
    final rid = item['id'], kind = item['kind'], agent = item['agent'];
    final runtime = pyTruthy(item['runtime']) ? item['runtime'] : '';
    final needs = pyTruthy(item['needs']) ? item['needs'] : const [];
    final pricing = pyTruthy(item['pricing']) ? item['pricing'] : '';
    if (!(rid is String &&
        _id.hasMatch(rid) &&
        (kind == 'online' || kind == 'local') &&
        agent is String &&
        _key.hasMatch(agent) &&
        needs is List &&
        needs.every((n) => n == 'mise' || n == 'node') &&
        (runtime == '' || (runtime is String && _key.hasMatch(runtime))) &&
        (kind != 'local' || runtime != '') &&
        (pricing == '' || (pricing is String && _pricing.hasMatch(pricing))))) {
      continue;
    }
    final title = _text(item['title'], 60);
    if (title.isEmpty) continue;
    final name = _text(item['name'], 40);
    routes.add(
      FirstAgentRoute(
        rid,
        kind as String,
        agent,
        title,
        _text(item['access'], 400),
        runtime as String,
        [...needs.cast<String>().toSet()],
        name.isEmpty ? title : name,
      ),
    );
  }
  return routes;
}

/// first_agent.load: a loaded add-on's first-agent.json first, else the app's.
final _repo = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}/[A-Za-z0-9][A-Za-z0-9._-]{0,95}$',
);
final _gguf = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.gguf$');
const _minContext = 16384;

int _positive(dynamic v) => v is int && v > 0 ? v : 0;

/// first_agent.Model: a starter model of the catalog.
typedef StarterModel = ({
  String id,
  String title,
  String repo,
  String file,
  int bytes,
  int minVram,
  String license,
  int context,
});

/// first_agent.parse's models: only entries that hold up.
List<StarterModel> parseModels(dynamic data) {
  final models = <StarterModel>[];
  if (data is! Map) return models;
  final items = pyTruthy(data['models']) ? data['models'] : const [];
  for (final item in items is List ? items : const []) {
    if (item is! Map) continue;
    final repo = item['repo'], name = item['file'], mid = item['id'];
    final size = _positive(item['bytes']), vram = _positive(item['min_vram']);
    final context = _positive(item['context']) != 0
        ? _positive(item['context'])
        : 32768;
    if (!(mid is String &&
        _id.hasMatch(mid) &&
        repo is String &&
        _repo.hasMatch(repo) &&
        name is String &&
        _gguf.hasMatch(name) &&
        size != 0 &&
        vram != 0 &&
        context >= _minContext)) {
      continue;
    }
    final title = _text(item['title'], 80);
    if (title.isEmpty) continue;
    models.add((
      id: mid,
      title: title,
      repo: repo,
      file: name,
      bytes: size,
      minVram: vram,
      license: _text(item['license'], 40),
      context: context,
    ));
  }
  return models;
}

/// ui_helpers.size_text: 2490000000 → "2.5 GB".
String decimalSize(int n) {
  for (final (size, unit) in [(1e12, 'TB'), (1e9, 'GB'), (1e6, 'MB')]) {
    if (n >= size) return '${pyFixedExact(n / size, 1)} $unit';
  }
  return '${(n < 0 ? 0 : n) ~/ 1000} kB';
}

/// first_agent.fit: fits (with its context), partly (some layers in RAM),
/// too large; unknown without a card.
String starterFit(StarterModel m, int vram) {
  if (vram != 0 && vram >= m.minVram) return 'fits';
  if (vram != 0 && vram >= m.bytes * 1.1) return 'partly';
  return vram != 0 ? 'too large' : 'unknown';
}

/// first_agent.suggested: the largest that fits; without one the smallest.
StarterModel? suggestedStarter(List<StarterModel> models, int vram) {
  final fitting = [
    for (final m in models)
      if (starterFit(m, vram) == 'fits') m,
  ];
  StarterModel? pick(List<StarterModel> list, bool largest) {
    StarterModel? best;
    for (final m in list) {
      if (best == null ||
          (largest ? m.bytes > best.bytes : m.bytes < best.bytes)) {
        best = m;
      }
    }
    return best;
  }

  return fitting.isNotEmpty ? pick(fitting, true) : pick(models, false);
}

/// The catalog's starter models, from the same file as the routes.
List<StarterModel> loadModels(Iterable<Addon> loaded) {
  final candidates = [
    for (final a in loaded)
      if (a.state == 'loaded' && a.files.containsKey('first-agent.json'))
        a.files['first-agent.json']!,
    utf8.encode(firstAgentCatalogText),
  ];
  for (final bytes in candidates) {
    if (bytes.length > _maxCatalog) continue;
    try {
      final data = jsonDecode(utf8.decode(bytes));
      if (parseRoutes(data).isNotEmpty) return parseModels(data);
    } on FormatException {
      continue;
    }
  }
  return [];
}

List<FirstAgentRoute> loadRoutes(Iterable<Addon> loaded) {
  final candidates = [
    for (final a in loaded)
      if (a.state == 'loaded' && a.files.containsKey('first-agent.json'))
        a.files['first-agent.json']!,
    utf8.encode(firstAgentCatalogText),
  ];
  for (final bytes in candidates) {
    if (bytes.length > _maxCatalog) continue;
    try {
      final found = parseRoutes(jsonDecode(utf8.decode(bytes)));
      if (found.isNotEmpty) return found;
    } on FormatException {
      continue;
    }
  }
  return [];
}

/// first_agent.has_tool: on PATH, or in ~/.local/bin (installed by the guide).
bool hasTool(String name, String home, String? path) {
  if (whichIn(name, path) != null) return true;
  try {
    final st = File('$home/.local/bin/$name').statSync();
    return st.type == FileSystemEntityType.file && st.mode & 0x40 != 0;
  } on FileSystemException {
    return false;
  }
}

/// first_agent.node_ready: Node on PATH, or mise's own.
bool nodeReady(String home, String? path) {
  if (hasTool('node', home, path)) return true;
  final installs = Directory('$home/.local/share/mise/installs/node');
  try {
    return installs.listSync().any(
      (e) =>
          FileSystemEntity.typeSync('${e.path}/bin/node') !=
          FileSystemEntityType.notFound,
    );
  } on FileSystemException {
    return false;
  }
}

/// agent_status.credentials_present: a key in the environment or a sign-in
/// file (a stat, never a read).
bool credentialsPresent(
  Map access,
  String home,
  Map<String, String> environment,
) {
  for (final name in (access['env'] as List? ?? const [])) {
    if ((environment['$name'] ?? '').isNotEmpty) return true;
  }
  for (final name in (access['files'] as List? ?? const [])) {
    if (FileSystemEntity.isFileSync('$home/$name')) return true;
  }
  return false;
}

/// flutter_first_agent.snapshot: each route's checklist.
Map<String, dynamic> guideSnapshot(
  AddonRegistry registry,
  ScanFiles files,
  AgentCatalog catalog,
  Map firstAgent,
  String Function(String) translate, {
  int vram = 0,
}) {
  final home = files.identity.home, path = files.identity.environment['PATH'];
  final routes = loadRoutes(registry.items);
  final starters = loadModels(registry.items);
  final verifiedAgents = firstAgent['verified'] is List
      ? firstAgent['verified'] as List
      : const [];
  final installed = {
    for (final a in catalog.scan())
      if (a.installed) a.command,
  };
  final runtimes = routes.any((r) => r.kind == 'local')
      ? ProviderScans(files).scan()
      : <RuntimeRecord>[];
  final installers = Installers(files);
  final llm = LocalLlm(files);
  Adapter? harness(String command) =>
      registry.adapters.where((a) => a.command == command).firstOrNull;
  final providers = [
    ...(visibleProviderFacts['local'] as List).cast<Map>(),
    ...(visibleProviderFacts['online'] as List).cast<Map>(),
  ];
  final rows = <Map<String, dynamic>>[];
  for (final route in routes) {
    final adapter = harness(route.agent);
    final access = adapter != null && adapter.facts.containsKey('access')
        ? adapter.table('access')
        : null;
    final present = installed.contains(route.agent);
    final steps = <Map<String, dynamic>>[];
    void step(
      String title,
      bool done, {
      String detail = '',
      String action = '',
      String? target,
      Map<String, dynamic>? starter,
    }) => steps.add({
      'title': title,
      'done': done,
      'detail': detail,
      'action': action,
      'target': ?target,
      'starter': ?starter,
    });
    if (adapter == null) {
      step(translate('Switch on its add-on'), false, action: 'addons');
    }
    final missing = [
      for (final need in route.needs)
        if (need == 'mise' && !hasTool('mise', home, path) ||
            need == 'node' && !nodeReady(home, path))
          need,
    ];
    for (final tool in route.needs) {
      var action = '';
      if (missing.contains(tool)) {
        if (tool == 'mise') {
          action = 'install-tool';
        } else if (tool == 'node' && hasTool('mise', home, path)) {
          action = 'install-node';
        }
      }
      step(tool, !missing.contains(tool), action: action, target: tool);
    }
    final agentAction =
        adapter != null && adapter.facts.containsKey('installer')
        ? 'install-agent'
        : 'install';
    step(
      route.name,
      present,
      action: present ? '' : (adapter != null ? agentAction : 'addons'),
    );
    if (route.kind == 'online') {
      final logins = access?['logins'] as List? ?? const [];
      step(
        translate('Sign in or set an API key'),
        present &&
            access != null &&
            credentialsPresent(access, home, files.identity.environment),
        detail: translate(route.access),
        action: present && access != null && logins.isNotEmpty ? 'login' : '',
      );
    } else {
      final runtime = runtimes.where((r) => r.key == route.runtime).firstOrNull;
      final provider = providers
          .where((p) => p['key'] == route.runtime)
          .firstOrNull;
      if (provider == null) {
        step(
          translate('Switch on its add-on'),
          false,
          detail: route.runtime,
          action: 'addons',
        );
      }
      final haveRuntime = runtime != null && runtime.installed;
      final inst = installers.find('runtime', route.runtime);
      step(
        provider != null ? '${provider['name']}' : route.runtime,
        haveRuntime,
        action: !haveRuntime && inst != null && inst.canInstall
            ? 'install-runtime'
            : 'providers',
        target: route.runtime,
      );
      // The starter model that fits the card, downloaded as the Models
      // page downloads one (first_agent_page.first_local_steps).
      final haveModel = runtime != null && runtime.models.isNotEmpty;
      final starter = suggestedStarter(starters, vram);
      final fit = starter == null ? '' : starterFit(starter, vram);
      step(
        translate('A model'),
        haveModel,
        detail: haveModel || starter == null
            ? ''
            : translate('{0}: {1}, {2} (fits your graphics card: {3})')
                  .replaceAll('{0}', translate('Suggested'))
                  .replaceAll('{1}', starter.title)
                  .replaceAll('{2}', decimalSize(starter.bytes))
                  .replaceAll(
                    '{3}',
                    translate(
                      const {
                            'fits': 'yes',
                            'partly': 'partly',
                            'too large': 'no',
                          }[fit] ??
                          'not known',
                    ),
                  ),
        action: !haveModel && haveRuntime && starter != null
            ? 'download-starter'
            : 'providers',
        target: !haveModel && haveRuntime && starter != null
            ? route.runtime
            : null,
        starter: !haveModel && haveRuntime && starter != null
            ? {
                'title': starter.title,
                'repo': starter.repo,
                'file': starter.file,
                'size': starter.bytes,
              }
            : null,
      );
      final connected =
          present &&
          runtime != null &&
          adapter != null &&
          llm.connected(adapter, route.runtime) &&
          llm.active(adapter, route.runtime);
      step(
        translate('Connections'),
        connected,
        detail: translate(
          'A preview shows what changes in its settings; Undo puts it back.',
        ),
        action: 'connections',
      );
    }
    final verified = present && verifiedAgents.contains(route.agent);
    final ask = adapter?.table('ask')['argv'] as List? ?? const [];
    step(
      translate('A test question'),
      verified,
      detail: translate(
        '{0} answers one short question, so you see that it works.',
      ).replaceAll('{0}', route.name),
      action: present && adapter != null && ask.isNotEmpty ? 'verify' : '',
    );
    rows.add({
      'id': route.id,
      'kind': route.kind,
      'title': translate(route.title),
      'access': translate(route.access),
      'command': route.agent,
      'name': route.name,
      'steps': steps,
      'verified': verified,
    });
  }
  return {'routes': rows, 'selected': firstAgent['route']};
}

/// AdapterRegistry.installed: the add-ons whose agent or local LLM this PC
/// has (each switched on for the look, then the choice put back).
List<String> setupInstalled(
  AddonRegistry registry,
  Set<String> enabled,
  ScanFiles files,
  AgentCatalog Function(List<Adapter>) catalogOf,
) {
  final ids = {
    for (final i in registry.items)
      if (supportedKinds.contains(i.kind) &&
          (i.state == 'verified' || i.state == 'loaded'))
        i.id,
  };
  final found = <String>{};
  try {
    registry.reload({...enabled, ...ids});
    final catalog = catalogOf(registry.adapters);
    List<RuntimeRecord>? runtimes;
    for (final item in registry.items) {
      if (!ids.contains(item.id) || item.state != 'loaded') continue;
      if (item.kind == 'provider' && item.provides.length > 1) {
        found.add(item.id);
      }
      for (final key in item.provides.take(1)) {
        if (item.kind == 'agent') {
          final adapter = registry.adapters
              .where((a) => a.command == key)
              .firstOrNull;
          if (catalog.detect(key, adapter).$1) found.add(item.id);
        }
        if (item.kind == 'provider' && item.provides.length == 1) {
          runtimes ??= ProviderScans(files).scan();
          if (runtimes.any((r) => r.key == key && r.installed)) {
            found.add(item.id);
          }
        }
      }
    }
  } finally {
    registry.reload(enabled);
  }
  return found.toList()..sort();
}
