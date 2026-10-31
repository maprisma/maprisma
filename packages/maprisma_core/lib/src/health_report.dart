import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart' show providerFacts;
import 'desktop.dart' show whichIn;
import 'installers.dart' show detectGpu;
import 'posix_ffi.dart';
import 'provider_facts.dart' show visibleProviderFacts;
import 'py_values.dart' show pyCompare;
import 'model_slots.dart' show needCount, slotHints;

/// health: how well the AI setup on this PC works, and what would make it
/// better. Reads only what was collected (agents and their checks, the
/// inventory, the map) plus a few facts about the PC. Areas (This PC,
/// Agents, Local LLMs and models, Tools) with findings: ok, a tip or
/// something to fix, each with an action; use cases (everyday help, vibe
/// coding, images, voice, research and writing): what is there for it and
/// the next step, judged by names against keyword lists.
/// Not ported yet: model_slots' warnings (the slots feature itself).

const gib = 1 << 30;

final coderRe = RegExp(
  r'cod(e|er|ing)|devstral|starcoder|codestral|swe',
  caseSensitive: false,
);
final visionRe = RegExp(
  r'(^|[-_.\s])(vl|vision|llava|pixtral|minicpm-v|moondream)([-_.\s]|$)|gemma-?[34]|mmproj',
  caseSensitive: false,
);
final imageGenRe = RegExp(
  r'flux|sdxl|stable-?diffusion|sd[-_]?3|hidream|qwen-?image',
  caseSensitive: false,
);
final imageToolRe = RegExp(
  r'photo|image|img|paint|draw|comfy|diffusion|gimp|krita|figma|canva|pixel|omaraw',
  caseSensitive: false,
);
final voiceRe = RegExp(
  r'tts|whisper|stt|speech|voice|kokoro|piper|parakeet|narrat',
  caseSensitive: false,
);
final webToolRe = RegExp(
  r'fetch|search|browser|chrome|playwright|puppeteer|web|tavily|brave|exa|firecrawl',
  caseSensitive: false,
);
final pcToolRe = RegExp(
  r'desktop|file|filesystem|shell|hypr|omarchy|system|computer|home|notes',
  caseSensitive: false,
);
const imageApps = [
  'comfyui',
  'sd',
  'sd-cli',
  'stable-diffusion',
  'krita',
  'gimp',
  'photocraft-cli',
  'omaraw',
];
const voiceApps = ['whisper', 'whisper-cli', 'piper', 'kokoro', 'espeak-ng'];

/// Python's "{:.Nf}": the nearest, a tie to the even digit.
String pyFixed(double x, int digits) {
  final scale = [1, 10, 100][digits];
  final scaled = x * scale;
  var n = scaled.floorToDouble();
  final rest = scaled - n;
  if (rest > 0.5 || (rest == 0.5 && n % 2 != 0)) n += 1;
  final text = (n / scale).toStringAsFixed(digits);
  return text;
}

String gbText(int size) => size >= 10 * gib
    ? '${pyFixed(size / gib, 0)} GB'
    : '${pyFixed(size / gib, 1)} GB';

/// health.fits_text: the model file size that runs well on this card.
String fitsText(int vram) {
  final usable = vram - (2.5 * gib).toInt();
  return gbText(usable < 0 ? 0 : usable);
}

/// Python's sorted(…, key=str.lower), stable.
List<String> _sortedLower(Iterable<String> items) {
  final list = items.toList();
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = pyCompare(a.$2.toLowerCase(), b.$2.toLowerCase());
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// health.matches: names that match, one per model.
List<String> matchNames(RegExp pattern, Iterable<String> names) {
  final found = <String, String>{};
  for (final name in names) {
    if (name.isNotEmpty && pattern.hasMatch(name)) {
      found.putIfAbsent(
        name.toLowerCase().split(':').first.replaceAll(RegExp('[^a-z0-9]'), ''),
        () => name,
      );
    }
  }
  return _sortedLower(found.values);
}

String _cut(String text, int limit) {
  final runes = text.runes;
  return runes.length <= limit ? text : String.fromCharCodes(runes.take(limit));
}

/// health.card_name.
String cardName(Map pc) {
  final gpu = '${pc['gpu'] ?? ''}';
  final brackets = [
    for (final m in RegExp(r'\[([^\]]+)\]').allMatches(gpu)) m[1]!,
  ];
  if (brackets.isNotEmpty) {
    final model = brackets.last.split('/').first.trim();
    final maker = const {'amd': 'AMD', 'nvidia': 'NVIDIA'}[pc['vendor']] ?? '';
    return maker.isNotEmpty && !model.toUpperCase().startsWith(maker)
        ? '$maker $model'.trim()
        : model;
  }
  return _cut(gpu.isNotEmpty ? gpu : '${pc['vendor']}'.toUpperCase(), 60);
}

/// health.first_local_llm: the first local LLM the app installs itself.
String firstLocalLlm() {
  final local = [
    for (final x in visibleProviderFacts['local'] as List)
      '${(x as Map)['key']}',
  ];
  final engines = providerFacts['engines'] as Map;
  return local
          .where((k) => (engines[k] as Map?)?['can_install'] != null)
          .firstOrNull ??
      local.firstOrNull ??
      '';
}

/// health.pc_info: the card, the memory, the free space in model folders.
Future<Map<String, dynamic>> pcInfo(List<String> modelDirs, String home) async {
  final gpu = await detectGpu();
  var ram = 0;
  try {
    final text = File('/proc/meminfo').readAsStringSync();
    final m = RegExp(r'^MemTotal:\s+(\d+)', multiLine: true).firstMatch(text);
    if (m != null) ram = int.parse(m[1]!) * 1024;
  } on Object {
    ram = 0;
  }
  final free = <String, int>{};
  final posix = Posix();
  for (final folder in modelDirs) {
    var probe = folder == '~' || folder.startsWith('~/')
        ? p.join(home, folder.length > 2 ? folder.substring(2) : '')
        : folder;
    while (FileSystemEntity.typeSync(probe) == FileSystemEntityType.notFound &&
        probe != p.dirname(probe)) {
      probe = p.dirname(probe);
    }
    final st = posix.statvfs(probe);
    if (st != null) free[folder] = st.bavail * st.frsize;
  }
  return {
    'vendor': gpu.vendor,
    'gpu': gpu.name,
    'vram': gpu.vram,
    'ram': ram,
    'cpus': Platform.numberOfProcessors,
    'free': free,
  };
}

Map<String, dynamic> finding(
  String level,
  String title, [
  String text = '',
  List<String> action = const [],
  String column = 'agents',
]) => {
  'level': level,
  'title': title,
  'text': text,
  'action': action,
  'column': column,
};

final class HealthReport {
  HealthReport({
    required this.tr,
    required this.plural,
    required this.desktopText,
    required this.home,
    this.searchPath,
  });
  final String Function(String) tr;
  final String Function(String one, String other, int n) plural;
  final String Function(String key) desktopText;
  final String home;
  final String? searchPath;

  String f(String text, List<Object?> args) {
    var out = tr(text);
    for (var i = 0; i < args.length; i++) {
      out = out.replaceAll('{$i}', '${args[i]}');
    }
    return out;
  }

  String n(String one, String other, int count) =>
      plural(one, other, count).replaceAll('{0}', '$count');

  /// health.check.
  Map<String, dynamic> check({
    required List<Map> agents,
    required Map<String, List<Map>> agentChecks,
    required Map<String, List<Map>> runtimeChecks,
    required List<Map> runtimes,
    required List<Map> mcp,
    required List<Map> skillSets,
    required Map<String, List<Map>> providers,
    required Map<String, Map> facts,
    required Map? graph,
    required Map pc,
    required Map failedLinks,
    List<Map> slotNeeds = const [],
  }) {
    final installed = agents.where((a) => a['installed'] == true).toList();
    final names = {for (final a in agents) '${a['command']}': '${a['name']}'};
    final rts = runtimes.where((r) => r['installed'] == true).toList();
    final models = {
      for (final rt in rts)
        for (final m in rt['models'] as List) '$m',
    }.toList()..sort(pyCompare);
    final mcpNames = [for (final m in mcp) '${m['name']}'];
    final usedMcp = mcp
        .where((m) => (m['agents'] as List? ?? const []).isNotEmpty)
        .toList();
    final skillNames = [
      for (final s in skillSets)
        '${p.basename('${s['path']}')} ${(s['skills'] as List).join(' ')}',
    ];
    final skillCount = skillSets.fold<int>(
      0,
      (a, s) => a + (s['skills'] as List).length,
    );
    final localAgents = {
      for (final rt in rts)
        for (final a in rt['agents'] as List? ?? const []) '$a',
    };
    final vram = pc['vram'] as int? ?? 0, ram = pc['ram'] as int? ?? 0;

    // This PC
    final pcArea = <Map<String, dynamic>>[];
    if (pc['vendor'] == 'cpu') {
      pcArea.add(
        finding(
          'hint',
          tr('No graphics card for local models'),
          tr(
            'Local models run on the processor: fine for small ones (up to about 4 GB), slow for bigger ones. Online models (Claude, Codex, Gemini) are not affected.',
          ),
          const [],
          'models',
        ),
      );
    } else if (vram < 8 * gib) {
      pcArea.add(
        finding(
          'hint',
          f('{0} with {1} video memory', [cardName(pc), gbText(vram)]),
          f('Good for small local models (model files up to about {0}).', [
            fitsText(vram),
          ]),
          const [],
          'models',
        ),
      );
    } else {
      pcArea.add(
        finding(
          'ok',
          f('{0} with {1} video memory', [cardName(pc), gbText(vram)]),
          f('Local models with files up to about {0} run fully on the card.', [
            fitsText(vram),
          ]),
          const [],
          'models',
        ),
      );
    }
    if (ram != 0) {
      pcArea.add(
        ram < 16 * gib
            ? finding(
                'hint',
                f('{0} memory', [gbText(ram)]),
                tr(
                  'Agents, a browser and a local model together get tight; close what you do not need.',
                ),
                const [],
                'models',
              )
            : finding(
                'ok',
                f('{0} memory', [gbText(ram)]),
                '',
                const [],
                'models',
              ),
      );
    }
    final free = (pc['free'] as Map? ?? const {}).cast<String, dynamic>();
    for (final folder in free.keys.toList()..sort(pyCompare)) {
      final bytes = free[folder] as int;
      final where = folder.replaceFirst(home, '~');
      if (bytes < 20 * gib) {
        pcArea.add(
          finding(
            'warn',
            f('Little free space for models: {0}', [gbText(bytes)]),
            f('In {0}. A model needs 2–30 GB; remove models no agent uses.', [
              where,
            ]),
            ['reorganize'],
            'models',
          ),
        );
      } else if (bytes < 60 * gib) {
        pcArea.add(
          finding(
            'hint',
            f('{0} free for models', [gbText(bytes)]),
            f('In {0}: room for a few more models.', [where]),
            const [],
            'models',
          ),
        );
      } else {
        pcArea.add(
          finding(
            'ok',
            f('{0} free for models', [gbText(bytes)]),
            where,
            const [],
            'models',
          ),
        );
      }
    }
    final areas = [
      {
        'key': 'pc',
        'title': tr('This PC'),
        'icon': '\u{f0379}',
        'findings': pcArea,
      },
    ];

    // Agents
    final agentArea = <Map<String, dynamic>>[];
    if (installed.isEmpty) {
      agentArea.add(
        finding(
          'warn',
          tr('No agent installed'),
          desktopText('install_agent_first'),
          ['firstagent'],
        ),
      );
    }
    final ready = <String>[];
    for (final agent in installed) {
      final checks = agentChecks['${agent['command']}'] ?? const [];
      final missing = checks.where((c) => c['state'] == 'missing').toList();
      final warn = checks.where((c) => c['state'] == 'warn').toList();
      String stepOf(Map c) =>
          '${c['step']}'.isNotEmpty ? '${c['step']}' : '${c['detail']}';
      if (missing.isNotEmpty) {
        agentArea.add(
          finding(
            'warn',
            '${agent['name']}: ${missing.first['title']}',
            stepOf(missing.first),
            ['details', '${agent['command']}'],
          ),
        );
      } else if (warn.isNotEmpty) {
        agentArea.add(
          finding(
            'hint',
            '${agent['name']}: ${warn.first['title']}',
            stepOf(warn.first),
            ['details', '${agent['command']}'],
          ),
        );
      } else {
        ready.add('${agent['name']}');
      }
    }
    if (ready.isNotEmpty) {
      agentArea.insert(
        0,
        finding(
          'ok',
          n('1 agent ready', '{0} agents ready', ready.length),
          ready.join(', '),
        ),
      );
    }
    if (rts.isNotEmpty && installed.isNotEmpty && localAgents.isEmpty) {
      agentArea.add(
        finding(
          'hint',
          tr('No agent uses your local LLMs yet'),
          f(
            'Draw a line on the map from an agent to {0}: it then works offline and free of charge as well.',
            [rts.first['name']],
          ),
        ),
      );
    }
    areas.add({
      'key': 'agents',
      'title': tr('Agents'),
      'icon': '\u{f06a9}',
      'findings': agentArea,
    });

    // Local LLMs and models
    final localArea = <Map<String, dynamic>>[];
    if (rts.isEmpty) {
      localArea.add(
        finding(
          'hint',
          tr('No local LLM installed'),
          tr(
            'Optional: a local LLM (llama.cpp or Ollama) runs models on this PC, private and without costs. Right-click llama.cpp on the map → Install.',
          ),
          ['install', firstLocalLlm()],
          'providers',
        ),
      );
    }
    for (final rt in rts) {
      final key = '${rt['key']}', name = '${rt['name']}';
      final rtModels = rt['models'] as List? ?? const [];
      final bad = (runtimeChecks[key] ?? const [])
          .where((c) => c['state'] == 'missing' || c['state'] == 'warn')
          .toList();
      if (bad.isNotEmpty) {
        final first = bad.first;
        localArea.add(
          finding(
            first['state'] == 'missing' ? 'warn' : 'hint',
            '$name: ${first['title']}',
            '${first['step']}'.isNotEmpty
                ? '${first['step']}'
                : '${first['detail']}',
            ['runtime', key],
            'providers',
          ),
        );
      } else if (rtModels.isEmpty) {
        localArea.add(
          finding(
            'hint',
            f('{0} has no models yet', [name]),
            vram != 0
                ? f(
                    'Download one that fits your card (files up to about {0}).',
                    [fitsText(vram)],
                  )
                : '',
            ['models', key, ''],
            'models',
          ),
        );
      } else {
        localArea.add(
          finding(
            'ok',
            name,
            n('1 model', '{0} models', rtModels.length) +
                (rt['running'] == true ? ' · ${tr('running')}' : ''),
            const [],
            'providers',
          ),
        );
      }
      if (rt['running'] == true &&
          (rt['active_agents'] as List? ?? const []).isEmpty &&
          (rt['agents'] as List? ?? const []).isNotEmpty) {
        localArea.add(
          finding(
            'hint',
            f('{0} runs, but no agent uses it now', [name]),
            tr(
              'It may hold video memory. With “Start local LLMs with their agents” on, it starts and stops with them.',
            ),
            ['runtime', key],
            'providers',
          ),
        );
      }
    }
    // Agents on different models of one local LLM: it must keep them all
    // loaded, and they must fit (model_slots).
    for (final need in slotNeeds) {
      for (final hint in slotHints(need, vram, tr)) {
        localArea.add(
          finding(
            'warn',
            f('{0}: its agents use {1} different models', [
              need['name'],
              needCount(need),
            ]),
            '${hint['text']}',
            ['runtime', '${need['key']}'],
            'providers',
          ),
        );
      }
    }
    // graph.idle_folders: model folders none of whose boxes an agent uses.
    final groups = <String, List<Map>>{};
    for (final node in (graph?['nodes'] as List? ?? const []).cast<Map>()) {
      if (node['column'] == 3 &&
          '${node['group'] ?? ''}'.isNotEmpty &&
          const ['model', 'more'].contains(node['kind'])) {
        groups.putIfAbsent('${node['group']}', () => []).add(node);
      }
    }
    final idle = [
      for (final e in groups.entries)
        if (!e.value.any((n) => n['active'] == true)) e.key,
    ]..sort(pyCompare);
    if (idle.isNotEmpty) {
      localArea.add(
        finding(
          'hint',
          n(
            '1 model folder no agent uses',
            '{0} model folders no agent uses',
            idle.length,
          ),
          f('{0}: connect an agent to them, or tidy up to free disk space.', [
            idle.map((x) => x.replaceFirst(home, '~')).join(', '),
          ]),
          ['reorganize'],
          'models',
        ),
      );
    }
    final seen = <String, Set<String>>{};
    for (final rt in rts) {
      for (final model in rt['models'] as List? ?? const []) {
        seen
            .putIfAbsent(
              '$model'
                  .toLowerCase()
                  .split(':')
                  .first
                  .replaceAll(RegExp('[^a-z0-9]'), ''),
              () => {},
            )
            .add('${rt['name']}');
      }
    }
    final doubled = seen.values.where((v) => v.length > 1).length;
    if (doubled != 0) {
      localArea.add(
        finding(
          'hint',
          n(
            "1 model is in more than one local LLM's folder",
            "{0} models are in more than one local LLM's folder",
            doubled,
          ),
          tr(
            'Reorganize puts them into one shared folder (no second copy, Undo possible).',
          ),
          ['reorganize'],
          'models',
        ),
      );
    }
    areas.add({
      'key': 'local',
      'title': tr('Local LLMs and models'),
      'icon': '\u{f0b79}',
      'findings': localArea,
    });

    // Tools: MCP servers and skills
    final tools = <Map<String, dynamic>>[];
    final linkKeys = [for (final k in failedLinks.keys) '$k']..sort(pyCompare);
    for (final key in linkKeys) {
      final at = key.indexOf('|');
      final source = at < 0 ? key : key.substring(0, at),
          target = at < 0 ? '' : key.substring(at + 1);
      String last(String x) =>
          x.contains(':') ? x.substring(x.indexOf(':') + 1) : x;
      final linkCol =
          target.startsWith('runtime:') || target.startsWith('provider:')
          ? 'providers'
          : 'mcp';
      tools.add(
        finding(
          'warn',
          f('A connection does not work: {0} → {1}', [
            names[last(source)] ?? last(source),
            last(target),
          ]),
          tr('Click its dotted red line on the map for what to do.'),
          ['link', source, target],
          linkCol,
        ),
      );
    }
    final unused = [
      for (final m in mcp)
        if ((m['agents'] as List? ?? const []).isEmpty) '${m['name']}',
    ];
    if (usedMcp.isNotEmpty) {
      tools.add(
        finding(
          'ok',
          n('1 MCP server in use', '{0} MCP servers in use', usedMcp.length),
          _cut(
            ([
              for (final m in usedMcp) '${m['name']}',
            ]..sort(pyCompare)).join(', '),
            200,
          ),
          const [],
          'mcp',
        ),
      );
    } else {
      tools.add(
        finding(
          'hint',
          tr('No MCP servers yet'),
          tr(
            'MCP servers give agents tools: files, a browser, your apps. Add MCP server finds them on this PC and on the web.',
          ),
          ['addmcp', ''],
          'mcp',
        ),
      );
    }
    if (unused.isNotEmpty) {
      tools.add(
        finding(
          'hint',
          n(
            '1 MCP server no agent uses',
            '{0} MCP servers no agent uses',
            unused.length,
          ),
          f('{0}: draw a line to an agent to use it.', [
            _cut((unused..sort(pyCompare)).join(', '), 200),
          ]),
          const [],
          'mcp',
        ),
      );
    }
    if (skillCount != 0) {
      tools.add(
        finding(
          'ok',
          n('1 skill', '{0} skills', skillCount),
          _cut(
            ({
              for (final s in skillSets) p.basename('${s['path']}'),
            }.toList()..sort(pyCompare)).join(', '),
            200,
          ),
          const [],
          'mcp',
        ),
      );
    } else {
      tools.add(
        finding(
          'hint',
          tr('No skills yet'),
          tr(
            'Skills teach agents a task step by step (a PDF, a release, your house style).',
          ),
          ['addskills'],
          'mcp',
        ),
      );
    }
    areas.add({
      'key': 'tools',
      'title': tr('Tools: MCP servers and skills'),
      'icon': '\u{f0841}',
      'findings': tools,
    });

    // What you can do with it
    bool has(String program) => whichIn(program, searchPath) != null;
    final coding = [
      for (final a in installed)
        if (facts['${a['command']}']?['chat_app'] != true) '${a['name']}',
    ];
    final online = [
      for (final a in installed)
        if ((providers['${a['command']}'] ?? const []).any(
              (x) => x['local'] != true,
            ) ||
            facts['${a['command']}']?['web_search'] == true)
          '${a['name']}',
    ];
    final uses = <Map<String, dynamic>>[];
    Map<String, dynamic> use(
      String key,
      String title,
      String icon,
      String blurb,
    ) => {
      'key': key,
      'title': tr(title),
      'icon': icon,
      'blurb': tr(blurb),
      'have': <String>[],
      'steps': <Map>[],
      'level': 'missing',
    };

    var u = use(
      'pc',
      'Everyday help on the PC',
      '\u{f0379}',
      'Ask questions, sort files, fix settings, explain errors.',
    );
    u['have'] = [
      ...installed.map((a) => '${a['name']}').take(4),
      ...matchNames(pcToolRe, mcpNames).take(3),
    ];
    if (installed.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'warn',
          tr('Install an agent'),
          desktopText('install_agent_short'),
        ),
      );
    } else if (rts.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('Quick answers offline'),
          tr(
            'A small local model (2–4 GB) answers simple questions without internet or costs.',
          ),
          ['install', firstLocalLlm()],
          'providers',
        ),
      );
    }
    uses.add(u);

    u = use(
      'coding',
      'Vibe coding',
      '\u{f0169}',
      'Describe what you want; the agent writes, runs and fixes the code.',
    );
    final coderModels = matchNames(coderRe, models);
    u['have'] = [
      ...coding.take(4),
      ...coderModels.take(2),
      if (skillCount != 0) n('1 skill', '{0} skills', skillCount),
    ];
    if (coding.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'warn',
          tr('Install a coding agent'),
          desktopText('install_coding_agent'),
        ),
      );
    }
    if (rts.isNotEmpty && coderModels.isEmpty && vram >= 6 * gib) {
      final rt = rts.first;
      (u['steps'] as List).add(
        finding(
          'hint',
          f('A coding model for {0}', [rt['name']]),
          f(
            'Search “coder” and take one marked as fitting ({0} or smaller): code without costs or limits.',
            [fitsText(vram)],
          ),
          ['models', '${rt['key']}', 'coder'],
          'models',
        ),
      );
    }
    if (coding.isNotEmpty && skillCount == 0) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('Add skills'),
          tr('Ready-made workflows (tests, reviews, releases).'),
          ['addskills'],
          'mcp',
        ),
      );
    }
    uses.add(u);

    u = use(
      'images',
      'Images',
      '\u{f02e9}',
      'Edit photos, cut out subjects, make and describe pictures.',
    );
    final imageTools = [
      ...matchNames(imageToolRe, mcpNames),
      ...imageApps.where(has),
    ];
    final vision = matchNames(visionRe, models),
        makers = matchNames(imageGenRe, models);
    u['have'] = [...imageTools.take(3), ...vision.take(2), ...makers.take(2)];
    if (imageTools.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('Add an image tool'),
          tr(
            'An MCP server for images lets agents edit pictures: Add MCP server, search “image”.',
          ),
          ['addmcp', 'image'],
          'mcp',
        ),
      );
    }
    if (rts.isNotEmpty && vision.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('A model that can see'),
          tr(
            'A vision model (names with VL, or Gemma) lets local agents read screenshots and photos.',
          ),
          ['models', '${rts.first['key']}', 'vl'],
          'models',
        ),
      );
    }
    uses.add(u);

    u = use(
      'voice',
      'Voice',
      '\u{f036c}',
      'Read texts aloud, write down what you say, subtitles.',
    );
    final voiceModels = matchNames(voiceRe, models);
    final voiceTools = [
      ...matchNames(voiceRe, [...mcpNames, ...skillNames]),
      ...voiceApps.where(has),
    ];
    u['have'] = [...voiceModels.take(3), ...voiceTools.take(3)];
    if ((u['have'] as List).isEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('A speech model'),
          tr(
            'Whisper (speech to text) or a TTS model (text to speech) run well locally.',
          ),
          rts.isNotEmpty
              ? ['models', '${rts.first['key']}', 'whisper']
              : const [],
          'models',
        ),
      );
    }
    uses.add(u);

    u = use(
      'research',
      'Research and writing',
      '\u{f0349}',
      'Search the web, read pages and documents, write and summarise.',
    );
    final webTools = matchNames(webToolRe, mcpNames);
    u['have'] = [
      ...(online.toSet().toList()..sort(pyCompare)).take(3),
      ...webTools.take(3),
    ];
    if (online.isEmpty && webTools.isEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('Web access'),
          tr(
            'Agents with online models search the web themselves; local ones need a search or browser MCP server.',
          ),
          ['addmcp', 'search'],
          'mcp',
        ),
      );
    } else if (webTools.isEmpty && localAgents.isNotEmpty) {
      (u['steps'] as List).add(
        finding(
          'hint',
          tr('Web access for local models'),
          tr(
            'A search or browser MCP server lets agents on local models look things up too.',
          ),
          ['addmcp', 'search'],
          'mcp',
        ),
      );
    }
    uses.add(u);

    for (final x in uses) {
      x['have'] = {...(x['have'] as List).cast<String>()}.toList();
      final steps = (x['steps'] as List).cast<Map>();
      final warn = steps.any((s) => s['level'] == 'warn');
      x['level'] = warn || (x['have'] as List).isEmpty
          ? 'missing'
          : steps.isNotEmpty
          ? 'almost'
          : 'ready';
    }
    var warnCount = 0, hintCount = 0;
    for (final a in areas) {
      for (final x in (a['findings'] as List).cast<Map>()) {
        if (x['level'] == 'warn') warnCount++;
        if (x['level'] == 'hint') hintCount++;
      }
    }
    final String summary;
    if (warnCount != 0) {
      summary =
          n('1 thing to fix', '{0} things to fix', warnCount) +
          (hintCount != 0 ? ' · ${n('1 tip', '{0} tips', hintCount)}' : '');
    } else if (hintCount != 0) {
      summary = '${tr('Works well')} · ${n('1 tip', '{0} tips', hintCount)}';
    } else {
      summary = tr('Everything set up and working');
    }
    return {
      'areas': areas,
      'uses': uses,
      'warn': warnCount,
      'hint': hintCount,
      'level': warnCount != 0
          ? 'warn'
          : hintCount != 0
          ? 'hint'
          : 'ok',
      'summary': summary,
    };
  }
}
