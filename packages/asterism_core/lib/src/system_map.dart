import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'adapters.dart';
import 'addons.dart' show AddonRegistry;
import 'agent_catalog.dart';
import 'desktop.dart' show whichIn;
import 'existing_ai.dart' as existing_ai;
import 'first_agent.dart' show loadRoutes;
import 'posix_ffi.dart';
import 'provider_facts.dart';
import 'provider_scans.dart';
import 'py_values.dart' show pyJsonDumps, pyCompare;
import 'scan_files.dart';
import 'system_map_cache.dart';

/// flutter_system_map: the System Map — this PC's hardware, disks, local
/// LLMs, agents, supporting tools and model folders, from files only (no
/// program is started, nothing is sent, no credential file is opened).

const _gib = 1024 * 1024 * 1024;
const _modelFolderNote =
    'A model folder is unavailable. Check its mount before downloading again.';

/// The built-in engines' program names (llm_engine.Engine.programs).
const enginePrograms = {
  'ollama': ['ollama'],
  'llamacpp': ['llama-server'],
  'jan': ['jan-llama-worker', 'jan-llama-worke'],
};

/// system_tools.small: at most 16 KiB of a regular file, never through a link.
String small(String path, [int limit = 16384]) {
  final posix = Posix();
  try {
    final fd = posix.openAt(
      -100,
      path,
      Posix.noFollow | Posix.nonBlock | Posix.cloexec,
    );
    try {
      if (posix.stat(fd).mode & 0xf000 != 0x8000) return '';
      return utf8.decode(posix.readAt(fd, 0, limit), allowMalformed: true);
    } finally {
      posix.close(fd);
    }
  } on FileSystemException {
    return '';
  }
}

String _realpath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

bool _within(String path, String root) =>
    path == root || p.isWithin(root, path);

/// system_tools.hardware.
Map<String, dynamic> hardware() {
  final ram = RegExp(
    r'^MemTotal:\s*(\d+)',
    multiLine: true,
  ).firstMatch(small('/proc/meminfo'));
  final gpus = <Map<String, dynamic>>[];
  List<String> cards;
  try {
    cards = [
      for (final e in Directory('/sys/class/drm').listSync(followLinks: false))
        if (RegExp(r'^card[0-9]').hasMatch(p.basename(e.path))) e.path,
    ]..sort();
  } on FileSystemException {
    cards = [];
  }
  for (final card in cards.take(16)) {
    final name = p.basename(card);
    if (name.contains('-')) continue;
    final vendor = small('$card/device/vendor').trim();
    const names = {'0x1002': 'AMD', '0x10de': 'NVIDIA', '0x8086': 'Intel'};
    const keys = {'0x1002': 'amd', '0x10de': 'nvidia', '0x8086': 'intel'};
    if (!names.containsKey(vendor)) continue;
    final size = small('$card/device/mem_info_vram_total').trim();
    gpus.add({
      'name': '${names[vendor]} · $name',
      'vendor': keys[vendor],
      'vram': RegExp(r'^\d+$').hasMatch(size) ? int.parse(size) : 0,
    });
  }
  return {
    'cpus': Platform.numberOfProcessors,
    'ram': ram != null ? int.parse(ram.group(1)!) * 1024 : 0,
    'gpus': gpus,
  };
}

const _tools = [
  ('python', 'Python', ['python3', 'python'], <String>[]),
  ('uv', 'uv', ['uv'], <String>[]),
  ('node', 'Node.js', ['node'], ['nodejs']),
  ('mise', 'mise', ['mise'], <String>[]),
  ('docker', 'Docker', ['docker'], <String>[]),
  ('podman', 'Podman', ['podman'], <String>[]),
  ('git', 'Git', ['git'], <String>[]),
  ('gcc', 'GCC', ['gcc'], <String>[]),
  ('clang', 'Clang', ['clang'], <String>[]),
  ('cmake', 'CMake', ['cmake'], <String>[]),
];

/// system_tools.detect: supporting tools on PATH (versions from file names
/// and folders only, with search).
List<Map<String, dynamic>> detectTools(
  Map<String, String> env,
  AgentCatalog catalog, {
  bool search = false,
}) {
  final result = <Map<String, dynamic>>[];
  for (final (key, name, commands, packages) in _tools) {
    final path =
        commands
            .map((c) => whichIn(c, env['PATH'] ?? ''))
            .whereType<String>()
            .firstOrNull ??
        '';
    if (path.isEmpty) continue;
    final real = _realpath(path);
    var version = '';
    if (search) {
      if (key == 'python') {
        version =
            RegExp(
              r'python(\d+\.\d+(?:\.\d+)?)$',
            ).firstMatch(p.basename(real))?.group(1) ??
            '';
        final cfg = small(p.join(p.dirname(p.dirname(real)), 'pyvenv.cfg'));
        final match = RegExp(
          r'^version\s*=\s*([\d.]+)',
          multiLine: true,
        ).firstMatch(cfg);
        if (match != null) version = match.group(1)!;
      }
      final parts = p.split(real);
      final i = parts.indexOf('installs');
      if (i >= 0 &&
          parts.length > i + 2 &&
          RegExp(
            r'^v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?$',
          ).hasMatch(parts[i + 2])) {
        version = parts[i + 2];
      }
      if (version.isEmpty) {
        version =
            [
              for (final x in packages.isEmpty ? [key] : packages)
                catalog.packageVersion(x),
            ].whereType<String>().where((v) => v.isNotEmpty).firstOrNull ??
            '';
      }
    }
    result.add({
      'key': key,
      'name': name,
      'path': path,
      'target': real,
      'version': version,
    });
  }
  final virtual = env['VIRTUAL_ENV'] ?? '';
  if (virtual.isNotEmpty && FileSystemEntity.isDirectorySync(virtual)) {
    result.add({
      'key': 'venv',
      'name': 'Python virtual environment',
      'path': virtual,
      'target': virtual,
      'version': '',
    });
  }
  return result;
}

/// system_tools.fstab_hint: an fstab line to review, for a whole-filesystem
/// UUID mount only.
String fstabHint(String path, [String? text]) {
  text ??= small('/proc/self/mountinfo', 128 * 1024);
  String decode(String v) => v.replaceAllMapped(
    RegExp(r'\\([0-7]{3})'),
    (m) => String.fromCharCode(int.parse(m[1]!, radix: 8)),
  );
  const local = {
    'ext4',
    'ext3',
    'ext2',
    'btrfs',
    'xfs',
    'f2fs',
    'zfs',
    'ntfs3',
    'exfat',
    'vfat',
  };
  for (final line in const LineSplitter().convert(text)) {
    final fields = line
        .split(RegExp(r'\s+'))
        .where((f) => f.isNotEmpty)
        .toList();
    final sep = fields.indexOf('-');
    if (sep < 0 || fields.length < 5 || sep + 2 >= fields.length) continue;
    if (decode(fields[4]) != path ||
        fields[3] != '/' ||
        !local.contains(fields[sep + 1])) {
      continue;
    }
    final source = decode(fields[sep + 2]);
    if (!source.startsWith('/dev/')) return '';
    var label = '';
    try {
      var i = 0;
      final real = _realpath(source);
      for (final entry in Directory(
        '/dev/disk/by-uuid',
      ).listSync(followLinks: false)) {
        if (i++ >= 128) break;
        final name = p.basename(entry.path);
        if (RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(name) &&
            _realpath(entry.path) == real) {
          label = name;
          break;
        }
      }
    } on FileSystemException {
      return '';
    }
    if (label.isEmpty) return '';
    const replacements = {
      ' ': r'\040',
      '\t': r'\011',
      '\n': r'\012',
      r'\': r'\134',
    };
    final escaped = path.split('').map((c) => replacements[c] ?? c).join();
    return 'UUID=$label $escaped ${fields[sep + 1]} defaults,nofail 0 2';
  }
  return '';
}

// --- the GPU stack (gpu_stack, read only) --------------------------------------------------------

List<String> _glob(String pattern) {
  // A shell pattern with * in its last one or more parts, sorted like glob.glob's.
  final parts = p.split(pattern);
  var found = <String>[parts.first];
  for (final part in parts.skip(1)) {
    final next = <String>[];
    for (final base in found) {
      if (!part.contains('*')) {
        final path = p.join(base, part);
        if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound ||
            part == parts.last) {
          next.add(path);
        }
        continue;
      }
      final re = RegExp('^${part.split('*').map(RegExp.escape).join('.*')}\$');
      try {
        for (final e in Directory(base).listSync(followLinks: false)) {
          final name = p.basename(e.path);
          if (!name.startsWith('.') && re.hasMatch(name)) next.add(e.path);
        }
      } on FileSystemException {
        continue;
      }
    }
    found = next;
  }
  return found
      .where(
        (x) => FileSystemEntity.typeSync(x) != FileSystemEntityType.notFound,
      )
      .toList();
}

String _gpuSmall(String path) {
  if (FileSystemEntity.isLinkSync(path) || !FileSystemEntity.isFileSync(path)) {
    return '';
  }
  try {
    if (File(path).lengthSync() > 64 * 1024) return '';
    return utf8.decode(File(path).readAsBytesSync(), allowMalformed: true);
  } on FileSystemException {
    return '';
  }
}

String _tilde(String path, String home) =>
    path.startsWith(home) ? '~${path.substring(home.length)}' : path;

/// gpu_stack.look(vendor, read_only=True): ROCm, Vulkan, CUDA and the PyTorch
/// builds, from files only.
Map<String, dynamic> gpuStack(
  String vendor,
  Map<String, String> env,
  String home,
) {
  var rocm = '';
  final roots = [
    env['ROCM_PATH'] ?? '',
    ...(_glob('/opt/rocm*')..sort((a, b) => pyCompare(b, a))),
  ];
  for (final root in roots.where((r) => r.isNotEmpty)) {
    final version = _gpuSmall('$root/.info/version').trim();
    if (_glob('$root/lib/libamdhip64.so*').isNotEmpty) {
      rocm = RegExp(r'^\d+\.\d+(\.\d+)?(-\d+)?$').hasMatch(version)
          ? version.split('-').first
          : 'yes';
      break;
    }
  }
  if (rocm.isEmpty &&
      (_glob('/usr/lib/libamdhip64.so*').isNotEmpty ||
          _glob('/usr/lib64/libamdhip64.so*').isNotEmpty)) {
    rocm = 'yes';
  }
  final vulkan =
      _glob('/usr/share/vulkan/icd.d/*.json').isNotEmpty ||
      _glob('/etc/vulkan/icd.d/*.json').isNotEmpty;
  final cuda =
      _glob('/usr/lib/libcuda.so*').isNotEmpty ||
          _glob('/usr/lib64/libcuda.so*').isNotEmpty ||
          whichIn('nvidia-smi', env['PATH'] ?? '') != null
      ? 'yes'
      : '';
  final places = <String>[];
  for (final pattern in [
    '/usr/lib/python3*/site-packages/torch',
    '$home/.local/lib/python3*/site-packages/torch',
    '$home/.local/share/mise/installs/python/*/lib/python3*/site-packages/torch',
    '$home/.local/share/*/venv/lib/python3*/site-packages/torch',
    '$home/.local/share/*/.venv/lib/python3*/site-packages/torch',
  ]) {
    places.addAll((_glob(pattern)..sort()).take(20));
  }
  final torches = <Map<String, String>>[];
  for (final folder in places.take(40)) {
    final text = _gpuSmall('$folder/version.py');
    final version = RegExp(
      r'''^__version__\s*=\s*['"]([^'"]{1,40})['"]''',
      multiLine: true,
    ).firstMatch(text);
    if (version == null) continue;
    final hip = RegExp(
      r'''^hip\s*(?::[^=\n]{0,40})?=\s*['"](\d+\.\d+)''',
      multiLine: true,
    ).firstMatch(text);
    final cu = RegExp(
      r'''^cuda\s*(?::[^=\n]{0,40})?=\s*['"](\d+\.\d+)''',
      multiLine: true,
    ).firstMatch(text);
    final where = folder.contains('site-packages')
        ? p.dirname(p.dirname(p.dirname(p.dirname(folder))))
        : folder;
    final found = {
      'where': _tilde(where, home),
      'version': version.group(1)!.split('+').first,
      'backend': hip != null
          ? 'ROCm ${hip.group(1)}'
          : cu != null
          ? 'CUDA ${cu.group(1)}'
          : 'CPU',
    };
    if (!torches.any(
      (t) =>
          t['where'] == found['where'] &&
          t['version'] == found['version'] &&
          t['backend'] == found['backend'],
    )) {
      torches.add(found);
    }
  }
  final summary = [
    if (rocm.isNotEmpty) rocm == 'yes' ? 'ROCm' : 'ROCm $rocm',
    if (vulkan) 'Vulkan',
    if (cuda.isNotEmpty) cuda == 'yes' ? 'CUDA' : 'CUDA $cuda',
  ];
  final missing = vendor != 'amd'
      ? <String>[]
      : [
          if (!vulkan && rocm.isEmpty) 'vulkan-radeon',
          if (rocm.isEmpty) 'rocm',
          if (torches.isNotEmpty &&
              !torches.any((t) => t['backend']!.startsWith('ROCm')))
            'pytorch-rocm',
        ];
  return {
    'summary': summary,
    'stack': {
      'rocm': rocm,
      'cuda': cuda,
      'vulkan': vulkan,
      'torch': torches,
      'missing': missing,
    },
  };
}

// --- health (its "This PC" and local LLM areas) ----------------------------------------------------

String gb(int size) => size >= 10 * _gib
    ? '${(size / _gib).toStringAsFixed(0)} GB'
    : '${(size / _gib).toStringAsFixed(1)} GB';
String fitsText(int vram) =>
    gb(vram - (2.5 * _gib).toInt() < 0 ? 0 : vram - (2.5 * _gib).toInt());

String cardName(String vendor, String gpu) {
  final brackets = RegExp(
    r'\[([^\]]+)\]',
  ).allMatches(gpu).map((m) => m.group(1)!).toList();
  if (brackets.isNotEmpty) {
    final model = brackets.last.split('/').first.trim();
    final maker = const {'amd': 'AMD', 'nvidia': 'NVIDIA'}[vendor] ?? '';
    return maker.isNotEmpty && !model.toUpperCase().startsWith(maker)
        ? '$maker $model'.trim()
        : model;
  }
  final name = gpu.isNotEmpty ? gpu : vendor.toUpperCase();
  return name.length > 60 ? name.substring(0, 60) : name;
}

/// health.check's "pc" and "local" areas with an empty graph and no runtime
/// checks (what the System Map asks of it), as the map's health rows.
List<Map<String, dynamic>> healthRows(
  Map<String, dynamic> pc,
  Map<String, int> free,
  List<RuntimeRecord> runtimes,
  List<String> folders,
  String home,
  String Function(String) tr,
  String Function(String, String, int) plural,
) {
  final vendor = pc['vendor'] as String, gpu = pc['gpu'] as String;
  final vram = pc['vram'] as int, ram = pc['ram'] as int;
  final rows = <Map<String, dynamic>>[];
  final pcFindings = <(String, String, String, List)>[];
  if (vendor == 'cpu') {
    pcFindings.add((
      'hint',
      tr('No graphics card for local models'),
      tr(
        'Local models run on the processor: fine for small ones (up to about 4 GB), slow for bigger ones. Online models (Claude, Codex, Gemini) are not affected.',
      ),
      [],
    ));
  } else if (vram < 8 * _gib) {
    pcFindings.add((
      'hint',
      tr(
        '{0} with {1} video memory',
      ).replaceAll('{0}', cardName(vendor, gpu)).replaceAll('{1}', gb(vram)),
      tr(
        'Good for small local models (model files up to about {0}).',
      ).replaceAll('{0}', fitsText(vram)),
      [],
    ));
  } else {
    pcFindings.add((
      'ok',
      tr(
        '{0} with {1} video memory',
      ).replaceAll('{0}', cardName(vendor, gpu)).replaceAll('{1}', gb(vram)),
      tr(
        'Local models with files up to about {0} run fully on the card.',
      ).replaceAll('{0}', fitsText(vram)),
      [],
    ));
  }
  if (ram > 0) {
    pcFindings.add(
      ram < 16 * _gib
          ? (
              'hint',
              tr('{0} memory').replaceAll('{0}', gb(ram)),
              tr(
                'Agents, a browser and a local model together get tight; close what you do not need.',
              ),
              [],
            )
          : ('ok', tr('{0} memory').replaceAll('{0}', gb(ram)), '', []),
    );
  }
  for (final folder in free.keys.toList()..sort(pyCompare)) {
    final room = free[folder]!;
    final where = folder.replaceFirst(home, '~');
    if (room < 20 * _gib) {
      pcFindings.add((
        'warn',
        tr('Little free space for models: {0}').replaceAll('{0}', gb(room)),
        tr(
          'In {0}. A model needs 2–30 GB; remove models no agent uses.',
        ).replaceAll('{0}', where),
        ['reorganize'],
      ));
    } else if (room < 60 * _gib) {
      pcFindings.add((
        'hint',
        tr('{0} free for models').replaceAll('{0}', gb(room)),
        tr('In {0}: room for a few more models.').replaceAll('{0}', where),
        [],
      ));
    } else {
      pcFindings.add((
        'ok',
        tr('{0} free for models').replaceAll('{0}', gb(room)),
        where,
        [],
      ));
    }
  }
  for (var index = 0; index < pcFindings.length; index++) {
    final (level, title, text, action) = pcFindings[index];
    // Missing sysfs VRAM is unknown, not a measured zero-byte GPU.
    if (index == 0 && vendor != 'cpu' && vram == 0) continue;
    var target = 'pc';
    for (final folder in folders) {
      if (text.contains(folder) ||
          text.contains(folder.replaceFirst(home, '~'))) {
        target = 'folder:$folder';
        break;
      }
    }
    if (target == 'pc' && gpu.isNotEmpty && title.contains(gpu)) {
      target = 'gpu';
    } else if (target == 'pc' && title.contains(gb(ram))) {
      target = 'ram';
    }
    rows.add({
      'node': target,
      'level': level,
      'title': title,
      'text': text,
      'action': action,
    });
  }
  final installed = runtimes.where((r) => r.installed).toList();
  final local = <(String, String, String, List)>[];
  if (installed.isEmpty) {
    final keys = [
      for (final f in visibleProviderFacts['local'] as List)
        (f as Map)['key'] as String,
    ];
    const installable = {
      'ollama',
      'llamacpp',
      'koboldcpp',
      'jan',
      'vllm',
      'lmstudio',
    };
    final first =
        keys.where(installable.contains).firstOrNull ?? keys.firstOrNull ?? '';
    local.add((
      'hint',
      tr('No local LLM installed'),
      tr(
        'Optional: a local LLM (llama.cpp or Ollama) runs models on this PC, private and without costs. Right-click llama.cpp on the map → Install.',
      ),
      ['install', first],
    ));
  }
  for (final rt in installed) {
    if (rt.models.isEmpty) {
      local.add((
        'hint',
        tr('{0} has no models yet').replaceAll('{0}', rt.name),
        vram > 0
            ? tr(
                'Download one that fits your card (files up to about {0}).',
              ).replaceAll('{0}', fitsText(vram))
            : '',
        ['models', rt.key, ''],
      ));
    } else {
      final count = plural(
        '1 model',
        '{0} models',
        rt.models.length,
      ).replaceAll('{0}', '${rt.models.length}');
      local.add((
        'ok',
        rt.name,
        count + (rt.running ? ' · ${tr('running')}' : ''),
        [],
      ));
    }
  }
  final seen = <String, Set<String>>{};
  for (final rt in installed) {
    for (final model in rt.models) {
      seen
          .putIfAbsent(
            model
                .toLowerCase()
                .split(':')
                .first
                .replaceAll(RegExp(r'[^a-z0-9]'), ''),
            () => {},
          )
          .add(rt.name);
    }
  }
  final doubled = seen.values.where((v) => v.length > 1).length;
  if (doubled > 0) {
    local.add((
      'hint',
      plural(
        "1 model is in more than one local LLM's folder",
        "{0} models are in more than one local LLM's folder",
        doubled,
      ).replaceAll('{0}', '$doubled'),
      tr(
        'Reorganize puts them into one shared folder (no second copy, Undo possible).',
      ),
      ['reorganize'],
    ));
  }
  for (final (level, title, text, action) in local) {
    final target = action.isNotEmpty && action.first == 'runtime'
        ? 'runtime:${action[1]}'
        : 'pc';
    rows.add({
      'node': target,
      'level': level,
      'title': title,
      'text': text,
      'action': action,
    });
  }
  return rows;
}

// --- the map ---------------------------------------------------------------------------------------

final class SystemMapReader {
  SystemMapReader(
    this.files,
    this.registry,
    this.catalog,
    this.tr,
    this.plural, {
    this.settingsPath,
    this.checksAgent = '',
  });
  final ScanFiles files;
  final AddonRegistry registry;
  final AgentCatalog catalog;
  final String Function(String) tr;
  final String Function(String, String, int) plural;
  final String? settingsPath; // null: the default settings file
  final String checksAgent; // the ai_checks_agent setting
  String get home => files.identity.home;
  Map<String, String> get env => files.identity.environment;
  String? which(String name) => whichIn(name, env['PATH'] ?? '');

  /// ai_helper.helpers / task_agents for the System Map's "ask AI" choices.
  List<Map<String, dynamic>> helpers(Set<String> installed) {
    bool closed(Adapter a) => a.facts.containsKey('closed');
    final able = [
      for (final a in registry.adapters)
        if (installed.contains(a.command) && which(a.command) != null) a,
    ];
    final researchers = [
      for (final a in able)
        if ((a.table('research')['argv'] as List? ?? []).isNotEmpty &&
            closed(a))
          a.command,
    ];
    final first = researchers.contains(checksAgent)
        ? checksAgent
        : researchers.firstOrNull;
    final taskable = [
      for (final a in able)
        if ((a.table('task')['argv'] as List? ?? []).isNotEmpty &&
            closed(a) &&
            (a.table('closed')['task'] as List? ?? []).isNotEmpty)
          a.command,
    ];
    final tasks = [
      if (taskable.contains(first)) first!,
      ...taskable.where((c) => c != first),
    ];
    String nameOf(String command) {
      final a = registry.adapters
          .where((x) => x.command == command)
          .firstOrNull;
      return a == null
          ? command
          : (a.fullName.isNotEmpty ? a.fullName : a.name);
    }

    return [
      for (final command in {...tasks, ...researchers})
        {
          'command': command,
          'name': nameOf(command),
          'check': researchers.contains(command),
          'task': tasks.contains(command),
        },
    ];
  }

  Map<String, dynamic> snapshot({bool search = false}) {
    final raw = hardware();
    final gpus = (raw['gpus'] as List).cast<Map<String, dynamic>>();
    var gpu = <String, dynamic>{'vendor': 'cpu', 'name': '', 'vram': 0};
    if (gpus.isNotEmpty) {
      gpu = gpus.first;
      for (final g in gpus) {
        if ((g['vram'] as int) > (gpu['vram'] as int)) gpu = g;
      }
    }
    final cpus = raw['cpus'] as int, ram = raw['ram'] as int;
    final pc = {
      'vendor': gpu['vendor'],
      'gpu': gpu['name'],
      'vram': gpu['vram'],
      'ram': ram,
      'cpus': cpus,
    };
    final machine = switch (Abi.current()) {
      Abi.linuxX64 => 'x86_64',
      Abi.linuxArm64 => 'aarch64',
      _ => '',
    };
    final pcInfo = '${pc['gpu']}'.isNotEmpty ? pc['gpu'] : pc['vendor'];
    final nodes = <Map<String, dynamic>>[
      {
        'id': 'pc',
        'label': 'This PC',
        'detail': 'Linux $machine · $cpus CPU · ${ram ~/ _gib} GiB RAM',
        'column': 0,
        'kind': 'hardware',
        'status': '',
        'path': '',
        'info': pcInfo,
      },
    ];
    final edges = <Map<String, String>>[];
    final byPath = <String, String>{};
    final mounts = existing_ai.mounts();
    void node(
      String ident,
      String label,
      String detail,
      int column,
      String kind, {
      String path = '',
      String status = '',
      String info = '',
    }) {
      if (nodes.length >= maxMapNodes || nodes.any((n) => n['id'] == ident)) {
        return;
      }
      nodes.add({
        'id': ident,
        'label': label,
        'detail': detail,
        'column': column,
        'kind': kind,
        'path': path,
        'status': status,
        'info': info,
      });
    }

    void edge(String source, String target) {
      if (edges.length < 512 &&
          !edges.any((e) => e['source'] == source && e['target'] == target)) {
        edges.add({'source': source, 'target': target});
      }
    }

    for (final (ident, label, detail) in [
      ('cpu', 'CPU threads', '$cpus'),
      ('ram', 'RAM', '${ram ~/ _gib} GiB'),
      ('gpu', 'GPU', '$pcInfo'),
    ]) {
      node(ident, label, detail, 0, 'hardware');
      edge('pc', ident);
    }
    var index = 0;
    for (final g in gpus.where((g) => !identical(g, gpu))) {
      index++;
      node(
        'gpu:$index',
        'GPU',
        '${g['name']}',
        0,
        'hardware',
        info: '${(g['vram'] as int) ~/ (1024 * 1024)} MiB',
      );
      edge('pc', 'gpu:$index');
    }
    final posix = Posix();
    for (final (path, label, fs) in [
      (home, 'Home folder', ''),
      for (final m in mounts) (m['path']!, 'Mounted disk', m['filesystem']!),
    ]) {
      final size = posix.statvfs(path);
      final detail = size == null
          ? ''
          : '${size.bavail * size.frsize ~/ _gib} / ${size.blocks * size.frsize ~/ _gib} GiB';
      final ident = 'disk:$path';
      node(ident, path, detail, 1, 'disk', path: path, info: fs);
      if (label == 'Mounted disk') {
        nodes.firstWhere((n) => n['id'] == ident)['fstab'] = fstabHint(path);
      }
      byPath[path] = ident;
      edge('pc', ident);
    }
    final folders = <String>[];
    void folder(String path, String label, String owner) {
      if (path.isEmpty || path.length > 4096) return;
      path = p.normalize(
        p.absolute(
          path == '~' || path.startsWith('~/')
              ? '$home${path.substring(1)}'
              : path,
        ),
      );
      final ident = 'folder:$path';
      node(
        ident,
        label,
        path,
        4,
        'folder',
        path: path,
        status: FileSystemEntity.isDirectorySync(path)
            ? 'available'
            : 'missing',
      );
      edge(owner, ident);
      final holding = byPath.keys.where((x) => _within(path, x)).toList();
      if (holding.isNotEmpty) {
        edge(
          byPath[holding.reduce((a, b) => b.length > a.length ? b : a)]!,
          ident,
        );
      }
      if (label == 'Models folder' && !folders.contains(path)) {
        folders.add(path);
      }
    }

    final runtimes = <RuntimeRecord>[];
    for (final rt in ProviderScans(
      files,
    ).scan(facts: providerFacts['local'] as List)) {
      if (!rt.installed) continue;
      runtimes.add(rt);
      final command =
          (enginePrograms[rt.key] ?? const [])
              .map(which)
              .whereType<String>()
              .firstOrNull ??
          '';
      final ident = 'runtime:${rt.key}';
      node(
        ident,
        rt.name,
        command.isNotEmpty ? command : rt.service,
        2,
        'runtime',
        path: command,
        status: rt.running ? 'running' : 'stopped',
        info: '${rt.models.length}',
      );
      edge('pc', ident);
      if (rt.modelsDir.isNotEmpty) folder(rt.modelsDir, 'Models folder', ident);
      if (rt.service.isNotEmpty) {
        node(
          'service:${rt.service}',
          '${rt.service}.service',
          rt.service,
          4,
          'service',
          path: '$home/.config/systemd/user/${rt.service}.service',
          status: rt.running ? 'running' : 'stopped',
        );
        edge(ident, 'service:${rt.service}');
        folder('$home/.config/systemd/user', 'Configuration', ident);
      }
    }
    final known = <String, Adapter>{
      for (final a in builtinAdapters()) a.command: a,
      for (final a in registry.adapters) a.command: a,
    };
    final installed = <String>{
      for (final a in catalog.scan())
        if (a.installed) a.command,
    };
    for (final h in known.values) {
      final visible = registry.adapters
          .where((a) => a.command == h.command)
          .firstOrNull;
      final (isInstalled, version, source) = catalog.detect(h.command, visible);
      if (!isInstalled) continue;
      final ident = 'agent:${h.command}';
      node(
        ident,
        h.fullName.isNotEmpty ? h.fullName : h.name,
        version.isNotEmpty ? version : source,
        2,
        'agent',
        path: which(h.command) ?? '',
        status: 'installed',
      );
      for (final n in nodes) {
        if (n['id'] == ident) n['install_source'] = source;
      }
      edge('pc', ident);
      final mcp = h.table('mcp')['path'];
      if (mcp is String && mcp.isNotEmpty) {
        folder(
          p.dirname(
            mcp == '~' || mcp.startsWith('~/')
                ? '$home${mcp.substring(1)}'
                : mcp,
          ),
          'Configuration',
          ident,
        );
      }
    }
    final tools = detectTools(env, catalog, search: search);
    for (final tool in tools) {
      node(
        'tool:${tool['key']}',
        '${tool['name']}',
        '${tool['version']}'.isNotEmpty
            ? '${tool['version']}'
            : '${tool['path']}',
        3,
        'tool',
        path: '${tool['path']}',
        status: 'installed',
        info: '${tool['target']}',
      );
      edge('pc', 'tool:${tool['key']}');
    }
    final toolIds = {for (final t in tools) t['key']};
    for (final h in known.values) {
      if (toolIds.contains('mise') &&
          nodes.any(
            (n) =>
                n['id'] == 'agent:${h.command}' &&
                n['install_source'] == 'mise',
          )) {
        edge('tool:mise', 'agent:${h.command}');
      }
    }
    for (final route in loadRoutes(const [])) {
      for (final need in route.needs) {
        if (toolIds.contains(need) &&
            nodes.any((n) => n['id'] == 'agent:${route.agent}')) {
          edge('tool:$need', 'agent:${route.agent}');
        }
      }
    }
    final stack = gpuStack('${pc['vendor']}', env, home);
    final gpuNode = nodes.firstWhere((n) => n['id'] == 'gpu');
    gpuNode['info'] = (stack['summary'] as List).join(' · ');
    gpuNode['stack'] = stack['stack'];
    final settingsFile = settingsPath ?? files.identity.settingsPath;
    Map saved = {};
    try {
      final data = jsonDecode(File(settingsFile).readAsStringSync());
      if (data is Map) saved = data;
    } catch (_) {
      saved = {};
    }
    final added = saved['model_folders'];
    if (added is List) {
      for (final x in added.take(128)) {
        if (x is String) folder(x, 'Models folder', 'pc');
      }
    }
    folder(p.dirname(settingsFile), 'Configuration', 'pc');
    final notes = <String>[];
    if (folders.any((x) => !FileSystemEntity.isDirectorySync(x))) {
      notes.add(_modelFolderNote);
    }
    final real = [for (final x in folders) _realpath(x)];
    if (real.length != real.toSet().length) {
      notes.add('Several paths point to the same model folder.');
    }
    if (real.toSet().length > 1) {
      notes.add(
        'Several model folders are configured. Review whether they can share storage.',
      );
    }
    final free = <String, int>{
      for (final x in folders)
        if (FileSystemEntity.isDirectorySync(x) && posix.statvfs(x) != null)
          x: posix.statvfs(x)!.bavail * posix.statvfs(x)!.frsize,
    };
    final health = healthRows(pc, free, runtimes, folders, home, tr, plural);
    final ids = {for (final n in nodes) n['id']};
    return boundedMap({
      'nodes': nodes,
      'edges': [
        for (final e in edges)
          if (ids.contains(e['source']) && ids.contains(e['target'])) e,
      ],
      'notes': notes,
      'helpers': helpers(installed),
      'limited': nodes.length >= maxMapNodes,
      'mounts': mounts,
      'records': <dynamic>[],
      'health': health,
      'version': 1,
      'checked_at': DateTime.now().microsecondsSinceEpoch / 1e6,
      'search_done': false,
    });
  }

  /// flutter_system_map.refresh: cheap facts first; disks searched on request
  /// or when a new one is mounted after the first search.
  Map<String, dynamic> refresh(
    String cachePath, {
    bool search = false,
    void Function(double, String)? progress,
  }) {
    progress ??= (_, _) {};
    final posix = Posix();
    final old = loadMapCache(cachePath, posix);
    progress(0.02, 'System Map');
    final result = snapshot(search: search);
    final mounts = (result['mounts'] as List).cast<Map<String, String>>();
    final signature = [for (final m in mounts) (m['path']!, m['identity']!)]
      ..sort((a, b) {
        final c = pyCompare(a.$1, b.$1);
        return c != 0 ? c : pyCompare(a.$2, b.$2);
      });
    result['mount_signature'] = pyJsonDumps([
      for (final s in signature) [s.$1, s.$2],
    ]);
    final oldMounts = (old['mounts'] as List? ?? const []).cast<Map>();
    final known = {
      for (final m in oldMounts) '${m['path']}\x00${m['identity']}',
    };
    final targets = [
      for (final m in mounts)
        if (search ||
            (old['search_done'] == true &&
                !known.contains('${m['path']}\x00${m['identity']}')))
          m,
    ];
    final searched = {for (final m in targets.take(16)) m['path']};
    final records = <dynamic>[
      for (final r in (old['records'] as List? ?? const []))
        if (!searched.contains(((r as Map)['mount'] as Map?)?['path'])) r,
    ];
    final limits = <Map<String, dynamic>>[];
    var i = 0;
    for (final mounted in targets.take(16)) {
      progress(
        0.1 + 0.65 * i / (targets.isEmpty ? 1 : targets.length),
        mounted['path']!,
      );
      i++;
      try {
        final found = existing_ai.scan(mounted['path']!, (_, _) {});
        records.addAll(found['records'] as List);
        limits.add({
          'path': mounted['path'],
          for (final k in ['limits', 'depth', 'notices', 'foreign'])
            k: found[k],
        });
      } on FormatException {
        limits.add({
          'path': mounted['path'],
          'limits': [],
          'depth': existing_ai.maxDepth,
          'notices': ['unavailable'],
          'foreign': [],
        });
      } on FileSystemException {
        limits.add({
          'path': mounted['path'],
          'limits': [],
          'depth': existing_ai.maxDepth,
          'notices': ['unavailable'],
          'foreign': [],
        });
      }
    }
    result['records'] = records.take(128).toList();
    result['scan_limits'] = targets.isNotEmpty
        ? limits
        : (old['scan_limits'] ?? []);
    result['search_done'] = search || old['search_done'] == true;
    result['searched_at'] = search
        ? DateTime.now().microsecondsSinceEpoch / 1e6
        : old['searched_at'];
    // Offline disks and what depends on them stay visible.
    final present = {for (final m in mounts) m['path']};
    final missing = {
      for (final m in oldMounts)
        if (!present.contains(m['path'])) '${m['path']}',
    };
    final resultNodes = result['nodes'] as List,
        resultEdges = result['edges'] as List;
    final currentIds = {for (final n in resultNodes) n['id']};
    final oldNodes = (old['nodes'] as List? ?? const []).cast<Map>();
    final oldEdges = (old['edges'] as List? ?? const []).cast<Map>();
    final offline = {
      for (final n in oldNodes)
        if ('${n['path'] ?? ''}'.isNotEmpty &&
            missing.any((x) => _within('${n['path']}', x)))
          n['id'],
    };
    for (final e in oldEdges) {
      if (offline.contains(e['target']) &&
          ('${e['source']}'.startsWith('runtime:') ||
              '${e['source']}'.startsWith('found:'))) {
        offline.add(e['source']);
      }
    }
    for (final n in oldNodes) {
      if (offline.contains(n['id']) && !currentIds.contains(n['id'])) {
        resultNodes.add(<String, dynamic>{
          ...n.cast<String, dynamic>(),
          'status': 'missing',
        });
        currentIds.add(n['id']);
      }
    }
    bool sameEdge(Map a, Map b) =>
        a['source'] == b['source'] &&
        a['target'] == b['target'] &&
        a.length == b.length;
    for (final e in oldEdges) {
      if (currentIds.contains(e['source']) &&
          currentIds.contains(e['target']) &&
          !resultEdges.any((x) => sameEdge(x as Map, e))) {
        resultEdges.add(Map<String, String>.from(e));
      }
    }
    result['mounts'] = [
      ...mounts,
      ...oldMounts.where((m) => !present.contains(m['path'])),
    ];
    for (final record in records.cast<Map>()) {
      final ident = 'found:${record['path']}';
      if (currentIds.contains(ident) ||
          resultNodes.any(
            (n) =>
                '${n['path'] ?? ''}'.isNotEmpty &&
                _realpath('${n['path']}') == record['path'],
          )) {
        continue;
      }
      final found = discoveryNode(record)
        ..['status'] = present.contains((record['mount'] as Map)['path'])
            ? 'found'
            : 'missing';
      resultNodes.add(found);
      resultEdges.add({
        'source': 'disk:${(record['mount'] as Map)['path']}',
        'target': ident,
      });
      currentIds.add(ident);
    }
    if (search) {
      _measure(resultNodes.cast<Map<String, dynamic>>());
    } else {
      final previous = {for (final n in oldNodes) n['id']: n};
      for (final n in resultNodes.cast<Map>()) {
        final before = previous[n['id']];
        if (before == null) continue;
        if (n['kind'] == 'tool' &&
            n['path'] == before['path'] &&
            n['detail'] == n['path']) {
          n['detail'] = before['detail'];
        }
        for (final k in ['size', 'size_partial']) {
          if (before.containsKey(k)) n[k] = before[k];
        }
      }
    }
    if (missing.isNotEmpty) (result['notes'] as List).add(_modelFolderNote);
    result['notes'] = (result['notes'] as List).toSet().toList();
    result['analysis'] = old['analysis'];
    result['move_undo'] = old['move_undo'];
    progress(0.95, 'System Map');
    return boundedMap(result);
  }

  /// The size search: space on disk (blocks) of folders and programs, each
  /// file once, three seconds in all (disk_usage.measure).
  void _measure(List<Map<String, dynamic>> nodes) {
    final items =
        <(Map<String, dynamic>, String, String)>[]; // node, kind, path
    for (final n in nodes) {
      if (!const {
            'folder',
            'models',
            'store',
            'agent',
            'runtime',
          }.contains(n['kind']) ||
          n['status'] == 'missing' ||
          '${n['path']}'.isEmpty) {
        continue;
      }
      final isFolder = const {'models', 'store', 'folder'}.contains(n['kind']);
      final path = isFolder ? '${n['path']}' : programPlace('${n['path']}');
      if (path != null) items.add((n, isFolder ? 'models' : 'program', path));
    }
    final ordered = [...items]
      ..sort(
        (a, b) =>
            (a.$2 == 'models' ? 0 : 1).compareTo(b.$2 == 'models' ? 0 : 1),
      );
    final seen = <String>{};
    final stopAt = DateTime.now().add(const Duration(seconds: 3));
    final sizes = <Map<String, dynamic>, (int, bool)>{};
    final posix = Posix();
    for (final (n, _, path) in ordered) {
      final (size, partial) = _walk(posix, path, seen, stopAt);
      final had = sizes[n];
      sizes[n] = ((had?.$1 ?? 0) + size, (had?.$2 ?? false) || partial);
    }
    for (final (n, _, _) in items) {
      final (size, partial) = sizes[n] ?? (0, false);
      // Shared program files may already have been counted for another node.
      if (const {'agent', 'runtime'}.contains(n['kind']) && size == 0) continue;
      n['size'] = size;
      n['size_partial'] = partial;
    }
  }

  (int, bool) _walk(
    Posix posix,
    String path,
    Set<String> seen,
    DateTime stopAt,
  ) {
    final info = posix.statBlocks(path);
    if (info == null) return (0, false);
    if (info.mode & 0xf000 != 0x4000) {
      final key = '${info.dev}:${info.ino}';
      return seen.add(key) ? (info.blocks * 512, false) : (0, false);
    }
    var size = 0, count = 0;
    final stack = [path];
    while (stack.isNotEmpty) {
      final folder = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = Directory(folder).listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        count++;
        if (count > 400000 ||
            (count % 2000 == 0 && DateTime.now().isAfter(stopAt))) {
          return (size, true);
        }
        final st = posix.statBlocks(entry.path);
        if (st == null) continue;
        if (!seen.add('${st.dev}:${st.ino}')) continue;
        final type = st.mode & 0xf000;
        if (type == 0x4000) {
          stack.add(entry.path);
        } else if (type != 0xa000) {
          size += st.blocks * 512;
        }
      }
    }
    return (size, false);
  }
}

/// flutter_system_map.program_place: a program's folder (links and known
/// wrapper scripts resolved); a script that leads nowhere known has none.
String? programPlace(String path) {
  final binary = _realpath(path);
  final target = scriptTarget(binary);
  if (target == null && small(binary).startsWith('#!')) return null;
  return programFolder(target ?? binary);
}

String? scriptTarget(String path) {
  try {
    if (File(path).lengthSync() > 16 * 1024) return null;
    final head = File(path).openSync();
    List<int> bytes;
    try {
      bytes = head.readSync(16 * 1024);
    } finally {
      head.closeSync();
    }
    if (bytes.length < 2 || bytes[0] != 0x23 || bytes[1] != 0x21) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    final rest = text.contains('\n')
        ? text.substring(text.indexOf('\n') + 1)
        : '';
    for (final m in RegExp(r'(/[A-Za-z0-9._+/-]{2,400})').allMatches(rest)) {
      final candidate = m.group(1)!;
      final st = FileStat.statSync(candidate);
      if (st.type == FileSystemEntityType.file &&
          st.mode & 0x49 != 0 &&
          !candidate.endsWith('.so')) {
        return candidate;
      }
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

String programFolder(String binary) {
  final home = Platform.environment['HOME'] ?? '/';
  final system = {'/', '/usr', '/usr/local', '/opt', home, '$home/.local'};
  final path = _realpath(binary);
  var folder = p.dirname(path);
  if (p.basename(folder) == 'bin') folder = p.dirname(folder);
  if (FileSystemEntity.typeSync('${p.dirname(folder)}/current') !=
          FileSystemEntityType.notFound &&
      !system.contains(p.dirname(folder))) {
    folder = p.dirname(folder);
  }
  return system.contains(folder) ||
          folder.startsWith('/usr/') ||
          folder.startsWith('/bin')
      ? path
      : folder;
}

/// SystemMap.forget_disk: one missing disk's saved facts, nothing else.
Map<String, dynamic> forgetDisk(String cachePath, Posix posix, String ident) {
  final live = existing_ai.mounts();
  return transactMapCache(cachePath, posix, (saved) {
    final disk = (saved['nodes'] as List? ?? const [])
        .cast<Map>()
        .where((n) => n['id'] == ident)
        .firstOrNull;
    if (disk == null || disk['kind'] != 'disk' || disk['status'] != 'missing') {
      throw const FormatException('Choose a missing disk');
    }
    final root = '${disk['path']}';
    if (live.any((m) => m['path'] == root)) {
      throw const FormatException('The disk is mounted again; refresh first');
    }
    final savedMounts = (saved['mounts'] as List).cast<Map>();
    if (!savedMounts.any((m) => m['path'] == root)) {
      throw const FormatException('Missing mount unavailable');
    }
    final others = [
      for (final m in [...savedMounts, ...live])
        if (m['path'] != root && _within('${m['path']}', root)) '${m['path']}',
    ];
    bool belongs(dynamic path) =>
        '${path ?? ''}'.isNotEmpty &&
        _within('$path', root) &&
        !others.any((o) => _within('$path', o));
    final removed = {
      for (final n in (saved['nodes'] as List).cast<Map>())
        if (n['id'] == ident ||
            (n['status'] == 'missing' && belongs(n['path'])))
          n['id'],
    };
    saved['nodes'] = [
      for (final n in saved['nodes'] as List)
        if (!removed.contains(n['id'])) n,
    ];
    saved['edges'] = [
      for (final e in saved['edges'] as List)
        if (!removed.contains(e['source']) && !removed.contains(e['target'])) e,
    ];
    saved['mounts'] = [
      for (final m in savedMounts)
        if (m['path'] != root) m,
    ];
    saved['records'] = [
      for (final r in (saved['records'] as List).cast<Map>())
        if ((r['mount'] as Map)['path'] != root && !belongs(r['path'])) r,
    ];
    saved['scan_limits'] = [
      for (final r in (saved['scan_limits'] as List? ?? const []).cast<Map>())
        if (!belongs(r['path'])) r,
    ];
    saved['health'] = [
      for (final r in (saved['health'] as List? ?? const []).cast<Map>())
        if (!removed.contains(r['node'])) r,
    ];
    final analysis = saved['analysis'];
    if (analysis is Map) {
      for (final f in (analysis['findings'] as List? ?? const []).cast<Map>()) {
        if (removed.contains(f['node'])) f['node'] = '';
      }
    }
    final view = saved['view'];
    if (view is Map && removed.contains(view['selected'])) {
      view['selected'] = null;
    }
    if (!(saved['nodes'] as List).any((n) => n['status'] == 'missing')) {
      saved['notes'] = [
        for (final n in saved['notes'] as List)
          if (n != _modelFolderNote) n,
      ];
    }
    return saved;
  });
}

/// Service.system_public: what Flutter sees of a map; cached discoveries
/// only as fresh opaque handles.
Map<String, dynamic> systemPublic(
  Map<String, dynamic> result,
  existing_ai.ExistingRecords existing,
) {
  if (result.isEmpty) {
    return {
      'version': 1,
      'nodes': [],
      'edges': [],
      'notes': [],
      'helpers': [],
      'limited': false,
      'checked_at': null,
    };
  }
  final public = existing.register({
    'records': result['records'] ?? [],
    'limited': false,
    'visited': 0,
  });
  final found = {
    for (final r in (public['items'] as List).cast<Map>()) r['path']: r,
  };
  const rootKeys = {
    'version',
    'checked_at',
    'searched_at',
    'edges',
    'notes',
    'helpers',
    'limited',
    'mounts',
    'scan_limits', //
    'analysis', 'health', 'move_undo', 'view', 'search_done', 'mount_signature',
  };
  const nodeKeys = {
    'id',
    'path',
    'kind',
    'label',
    'detail',
    'info',
    'status',
    'column',
    'mount_path',
    'size',
    'size_partial', //
    'stack', 'fstab', 'install_source', 'launch_path',
  };
  final visible = <String, dynamic>{
    for (final e in result.entries)
      if (rootKeys.contains(e.key)) e.key: e.value,
  };
  visible['nodes'] = [
    for (final n in (result['nodes'] as List).cast<Map>())
      {
        for (final e in n.entries)
          if (nodeKeys.contains(e.key)) e.key as String: e.value,
      },
  ];
  final analysis = visible['analysis'];
  if (analysis is Map) {
    visible['analysis'] = {
      for (final k in ['agent', 'when', 'summary', 'findings'])
        if (analysis.containsKey(k)) k: analysis[k],
    };
  }
  for (final n in (visible['nodes'] as List).cast<Map<String, dynamic>>()) {
    final path = '${n['path']}'.isNotEmpty ? _realpath('${n['path']}') : '';
    final hit = found[path];
    if (const {'runtime', 'folder', 'models', 'store'}.contains(n['kind']) &&
        hit != null &&
        n['status'] != 'missing') {
      n['found'] = hit['found'];
      n['provider'] = hit['provider'];
      if (n['kind'] == 'folder' &&
          const {'models', 'store'}.contains(hit['kind'])) {
        n['kind'] = hit['kind'];
      }
    }
  }
  return visible;
}
