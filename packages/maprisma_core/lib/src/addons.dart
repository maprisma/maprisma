import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'adapters.dart';
import 'posix_ffi.dart';
import 'provider_facts.dart';
import 'sshsig.dart';

/// Add-ons, verified as `addons.verify` does and loaded as data only (Uwe,
/// 2026-10-29): nothing of an add-on runs. An agent add-on's agent.toml is
/// read from its verified bytes; the code the app's own signed add-ons carry
/// (its providers, the online providers, the hooks of its built-in agents)
/// is built into this core, which uses its own; any other code: refused,
/// until the catalog has a data version.

/// Uwe Bruckhaus's add-on signing key (SHA256:e5cC634Ke3Our5LAeSc88qs22NKZEHTncBW5Ig3amWQ).
const signingKey =
    'AAAAC3NzaC1lZDI1NTE5AAAAIFfDZiRAvEhdsjhLIlYc6SfP80I533WGiSw6/tzqQtYA';
const signingNamespace = 'maprisma-addon';

/// addons.LEGACY_*: add-ons signed for Asterism (this app's old name) with its
/// old key are never loaded, but recognised, so their card says what they are.
const legacyNamespace = 'asterism-addon';
const legacyKey =
    'AAAAC3NzaC1lZDI1NTE5AAAAIEIPZnfPIkyy+IX1J0jfB5g/U8U5jjJTapOogzlKrxlo';
const legacyReason = "made for Asterism, this app's old name";
const maprismaVersion = '0.14.5';
const apiVersion = 1;
const addonKinds = {'feature', 'agent', 'provider', 'extension'};
const addonCapabilities = {'agent', 'provider', 'installer', 'updater'};
const privacyLevels = {'numbers': 1, 'titles': 2, 'summary': 3};
const supportedKinds = {'agent', 'provider'};
const maxFiles = 64, maxFile = 1024 * 1024, maxTotal = 4 * 1024 * 1024;
const maxManifest = 64 * 1024, maxSignature = 8 * 1024;

/// The built-in agents whose hooks this core implements itself.
const builtInHooks = {'dsh', 'hermes', 'omp', 'openclaw', 'opencode', 'pi'};

/// harnesses._MODULES: Omarchy's menu order, then the app's own.
const agentOrder = [
  'claude',
  'codex',
  'copilot',
  'crush',
  'cursor-agent',
  'gemini',
  'grok',
  'hermes',
  'muse',
  'omp',
  'openclaw',
  'opencode',
  'pi',
  'dsh',
  'bionic',
  'agy',
  'goose',
];

final _id = RegExp(r'^[a-z][a-z0-9-]{1,40}$');
final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
final _lang = RegExp(r'^translations/[a-z]{2}\.json$');
final _line = RegExp(r'^([0-9a-f]{64})  (\S{1,200})$');
final _homepage = RegExp(
  r'^https://[A-Za-z0-9.-]{1,100}(/[A-Za-z0-9._~%/+@-]*)?$',
);
final _icon = RegExp(r'^[a-z0-9-]{1,60}$');
final _command = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');
final _needs = RegExp(r'^(?:maprisma\s*>=\s*)?(\d{1,4}\.\d{1,4}\.\d{1,4})$');

final class Addon {
  Addon(this.folder) : id = p.basename(folder);
  final String folder, id;
  String name = '', version = '', kind = 'feature', icon = '', summary = '';
  String description = '', homepage = '', needs = '', state = 'refused';
  String reason = '';
  int api = 0, privacy = 0;
  List<String> harnesses = [], reads = [], sends = [], capabilities = [];
  List<String> extends_ = [], provides = [], commands = [], paths = [];
  Map<String, List<int>> files = {};

  bool get bringsCode =>
      files.containsKey('addon.py') || files.containsKey('hooks.py');
}

Addon _refuse(Addon addon, String reason) {
  addon.state = 'refused';
  addon.reason = reason;
  addon.files = {};
  return addon;
}

List<int> _version3(String v) {
  try {
    return [for (final x in v.split('.')) int.parse(x)];
  } on FormatException {
    return [];
  }
}

bool _newer(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : -1, y = i < b.length ? b[i] : -1;
    if (x != y) return x > y;
  }
  return false;
}

List<String> _texts(dynamic value, [int limit = 12]) => value is! List
    ? []
    : [
        for (final v in value.take(limit))
          if (v is String && v.trim().isNotEmpty)
            _cut(v.trim().split(RegExp(r'\s+')).join(' '), 300),
      ];

String _cut(String text, int n) => String.fromCharCodes(text.runes.take(n));

String _oneLine(dynamic value, int n) => _cut(
  '${value ?? ''}'
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' '),
  n,
);

/// icons.safe_svg: shapes only.
bool safeSvg(List<int> data) {
  const shapes = {
    'svg',
    'g',
    'path',
    'circle',
    'ellipse',
    'rect',
    'line',
    'polyline',
    'polygon',
    'defs',
    'title',
    'desc',
    'clippath',
    'mask',
    'lineargradient',
    'radialgradient',
    'stop',
  };
  if (data.isEmpty || data.length > 64 * 1024) return false;
  final String text;
  try {
    text = utf8.decode(data);
  } on FormatException {
    return false;
  }
  final lowered = text.toLowerCase();
  if (lowered.contains('<!doctype') ||
      lowered.contains('<!entity') ||
      lowered.contains('<?xml-stylesheet')) {
    return false;
  }
  for (final m in RegExp(r'<\s*([a-zA-Z][\w:.-]*)').allMatches(text)) {
    if (!shapes.contains(m[1]!.split(':').last.toLowerCase())) return false;
  }
  for (final m in RegExp(
    r'''href\s*=\s*["']([^"']*)["']''',
    caseSensitive: false,
  ).allMatches(text)) {
    if (!m[1]!.startsWith('#')) return false;
  }
  for (final m in RegExp(
    r'url\(\s*([^)]*)\)',
    caseSensitive: false,
  ).allMatches(text)) {
    if (!m[1]!.replaceAll(RegExp(r'''^[ '"]+|[ '"]+$'''), '').startsWith('#')) {
      return false;
    }
  }
  if (RegExp(r'\son\w+\s*=', caseSensitive: false).hasMatch(text) ||
      lowered.contains('javascript:') ||
      lowered.contains('@import')) {
    return false;
  }
  return lowered.contains('<svg');
}

final class AddonVerifier {
  AddonVerifier(this.posix);
  final Posix posix;
  int get uid => posix.uid;

  bool _trusted(int mode, int owner) =>
      (owner == uid || owner == 0) && mode & 0x12 == 0;

  /// _read: a regular, trusted file's bytes (no link followed), or null.
  List<int>? read(String path, int limit) {
    int? fd;
    try {
      fd = posix.openAt(
        -100,
        path,
        Posix.noFollow | Posix.cloexec | Posix.nonBlock,
      );
      final st = posix.statFull(fd);
      if (st.mode & 0xf000 != 0x8000 ||
          !_trusted(st.mode, st.uid) ||
          st.size > limit) {
        return null;
      }
      final data = posix.readPrefix(fd, limit + 1);
      return data.length <= limit ? data : null;
    } on FileSystemException {
      return null;
    } finally {
      if (fd != null) posix.close(fd);
    }
  }

  /// _files: every file below the folder, or why it is refused.
  Object files(String folder) {
    final found = <String>[];
    final stack = [(folder, '')];
    while (stack.isNotEmpty) {
      final (current, prefix) = stack.removeLast();
      final st = posix.lstatOwn(current);
      if (st == null) return 'cannot be read';
      if (st.mode & 0xf000 != 0x4000 || !_trusted(st.mode, st.uid)) {
        return 'folder ${prefix.isEmpty ? '.' : prefix} is a link, not yours or writable by others';
      }
      List<FileSystemEntity> items;
      try {
        items = Directory(current).listSync(followLinks: false);
      } on FileSystemException {
        return 'cannot be read';
      }
      for (final item in items) {
        final rel = prefix + p.basename(item.path);
        final type = FileSystemEntity.typeSync(item.path, followLinks: false);
        if (type == FileSystemEntityType.link) return '$rel is a link';
        if (type == FileSystemEntityType.directory) {
          if (prefix.isNotEmpty) {
            return '$rel: folders may only be one level deep';
          }
          stack.add((item.path, '$rel/'));
        } else {
          found.add(rel);
        }
        if (found.length > maxFiles) return 'too many files';
      }
    }
    return found..sort();
  }

  /// addons.verify: the add-on checked completely.
  Addon verify(String folder) {
    final addon = Addon(folder);
    if (!_id.hasMatch(addon.id)) {
      return _refuse(addon, 'the folder name is not an add-on id');
    }
    final names = files(folder);
    if (names is String) return _refuse(addon, names);
    final list = names as List<String>;
    const allowed = {
      'addon.json',
      'addon.py',
      'agent.toml',
      'hooks.py',
      'MANIFEST.sha256',
      'SIGNATURE',
      'icon.svg',
    };
    final strange = list.where(
      (n) => !allowed.contains(n) && !_lang.hasMatch(n),
    );
    if (strange.isNotEmpty) {
      return _refuse(addon, 'unexpected file ${strange.first}');
    }
    if (!list.contains('SIGNATURE') || !list.contains('MANIFEST.sha256')) {
      return _refuse(addon, 'not signed');
    }
    final manifest = read(p.join(folder, 'MANIFEST.sha256'), maxManifest);
    final signature = read(p.join(folder, 'SIGNATURE'), maxSignature);
    if (manifest == null || signature == null) {
      return _refuse(addon, 'the signature files cannot be read safely');
    }
    if (!sshSignatureOk(manifest, signature, signingNamespace, signingKey)) {
      return _refuse(
        addon,
        sshSignatureOk(manifest, signature, legacyNamespace, legacyKey)
            ? legacyReason
            : 'not signed by Uwe Bruckhaus',
      );
    }
    final listed = <String, String>{};
    for (final line in const LineSplitter().convert(
      utf8.decode(manifest, allowMalformed: true),
    )) {
      final m = _line.firstMatch(line);
      if (m == null || listed.containsKey(m[2])) {
        return _refuse(addon, 'the manifest is malformed');
      }
      listed[m[2]!] = m[1]!;
    }
    final expected = list.toSet()..removeAll({'MANIFEST.sha256', 'SIGNATURE'});
    if (listed.keys.toSet().length != expected.length ||
        !expected.containsAll(listed.keys)) {
      return _refuse(addon, 'files differ from the signed list');
    }
    final verified = <String, List<int>>{};
    var total = 0;
    for (final e in listed.entries) {
      final data = read(p.join(folder, e.key), maxFile);
      if (data == null) return _refuse(addon, '${e.key} cannot be read safely');
      total += data.length;
      if (total > maxTotal) return _refuse(addon, 'too large');
      if (sha256.convert(data).toString() != e.value) {
        return _refuse(addon, '${e.key} was changed');
      }
      verified[e.key] = data;
    }
    dynamic meta;
    try {
      meta = jsonDecode(utf8.decode(verified['addon.json']!));
    } catch (_) {
      return _refuse(addon, 'addon.json is missing or not JSON');
    }
    if (meta is! Map || meta['id'] != addon.id) {
      return _refuse(addon, 'addon.json does not name this add-on');
    }
    // Maprisma's provider add-ons are data: they name built-in providers.
    final named = meta['provides'];
    final builtInProviders =
        meta['kind'] == 'provider' &&
        named is List &&
        named.isNotEmpty &&
        named.every(providerFactsAll().contains);
    if (!verified.containsKey('addon.py') &&
        !verified.containsKey('agent.toml') &&
        !builtInProviders) {
      return _refuse(addon, 'addon.py (or an agent\'s agent.toml) is missing');
    }
    if (verified.containsKey('agent.toml') && meta['kind'] != 'agent') {
      return _refuse(addon, 'agent.toml belongs only in an agent add-on');
    }
    if (verified.containsKey('hooks.py') &&
        !verified.containsKey('agent.toml')) {
      return _refuse(addon, 'hooks.py belongs beside an agent.toml');
    }
    final version = meta['version'],
        api = meta['api'],
        privacy = meta['privacy'];
    if (version is! String || !_version.hasMatch(version)) {
      return _refuse(addon, 'the version is not x.y.z');
    }
    if (api != apiVersion) {
      return _refuse(
        addon,
        'made for add-on API $api, this Maprisma has $apiVersion',
      );
    }
    if (!privacyLevels.containsKey(privacy)) {
      return _refuse(addon, 'unknown privacy level');
    }
    addon
      ..name = _oneLine(
        meta['name'] == null || meta['name'] == '' || meta['name'] == false
            ? addon.id
            : meta['name'],
        80,
      )
      ..version = version
      ..api = api as int
      ..privacy = privacyLevels[privacy]!;
    final kind = meta['kind'] ?? 'feature', needs = meta['needs'] ?? '';
    if (!addonKinds.contains(kind)) return _refuse(addon, 'unknown kind');
    final m = needs is String && needs.isNotEmpty
        ? _needs.firstMatch(needs.trim())
        : null;
    if (needs != '' && m == null) {
      return _refuse(addon, 'needs is not "maprisma >= x.y.z"');
    }
    if (m != null && _newer(_version3(m[1]!), _version3(maprismaVersion))) {
      return _refuse(
        addon,
        'made for Maprisma ${m[1]} or newer, this is $maprismaVersion',
      );
    }
    addon
      ..kind = kind as String
      ..needs = m?[1] ?? '';
    final icon = meta['icon'];
    addon.icon = icon is String && _icon.hasMatch(icon) ? icon : '';
    final home = meta['homepage'];
    addon.homepage =
        home is String && home.length <= 300 && _homepage.hasMatch(home)
        ? home
        : '';
    addon.summary = _oneLine(meta['summary'], 200);
    addon.description = _oneLine(meta['description'], 2000);
    final detect = meta['detect'] is Map ? meta['detect'] as Map : const {};
    final commands = detect['commands'], paths = detect['paths'];
    addon.commands = commands is List
        ? [
            for (final c in commands.take(8))
              if (c is String && _command.hasMatch(c)) c,
          ]
        : [];
    addon.paths = paths is List
        ? [
            for (final x in paths.take(8))
              if (x is String &&
                  x.startsWith('~/') &&
                  !x.contains('..') &&
                  x.length <= 200 &&
                  !x.codeUnits.any((c) => c < 32))
                x,
          ]
        : [];
    final provides = meta['provides'] ?? [];
    addon.provides = provides is List && (kind == 'agent' || kind == 'provider')
        ? [
            for (final x in provides.take(40))
              if (x is String && _command.hasMatch(x)) x,
          ]
        : [];
    final extends_ = meta['extends'] ?? [];
    addon.extends_ = extends_ is List && kind == 'extension'
        ? [
            for (final x in extends_.take(40))
              if (x is String && _command.hasMatch(x)) x,
          ]
        : [];
    if (kind == 'extension' && addon.extends_.isEmpty) {
      return _refuse(addon, 'an extension names no agent in "extends"');
    }
    final capabilities = meta['capabilities'] ?? [];
    if (capabilities is! List ||
        !capabilities.every(addonCapabilities.contains)) {
      return _refuse(addon, 'unknown capabilities');
    }
    addon
      ..harnesses = _texts(meta['harnesses'])
      ..reads = _texts(meta['reads'])
      ..sends = _texts(meta['sends'])
      ..capabilities = ({for (final c in capabilities) c as String}.toList()
        ..sort());
    if (verified.containsKey('icon.svg') && !safeSvg(verified['icon.svg']!)) {
      return _refuse(
        addon,
        'icon.svg may only hold shapes (no scripts, links, images or styles)',
      );
    }
    addon
      ..files = verified
      ..state = 'verified'
      ..reason = '';
    return addon;
  }
}

/// harnesses.NEWER_FACTS as agent.toml keys: what an add-on signed before
/// them does not bring is taken from the app's own adapter.
const _newerKeys = [
  'home',
  'activity',
  'details',
  'program_dir',
  'web_search',
  'chat_app',
  'herdr',
  'start',
  'rewrite',
  'task',
  'closed',
  'advise',
  'models',
  'tools',
  'replies',
  'subagents',
  'sessions',
  'install_marks',
  'plan_limits',
];

bool _emptyFact(dynamic v) =>
    v == null ||
    v == '' ||
    v == false ||
    (v is List && v.isEmpty) ||
    (v is Map && v.isEmpty);

/// harnesses._with_newer_facts on the TOML facts.
Map<String, dynamic> withNewerFacts(
  Map<String, dynamic> facts,
  Map<String, dynamic>? own,
) {
  if (own == null) return facts;
  final merged = Map<String, dynamic>.from(facts);
  for (final key in _newerKeys) {
    if (_emptyFact(merged[key]) && !_emptyFact(own[key])) {
      merged[key] = own[key];
    }
  }
  Map table(Map<String, dynamic> f, String key) =>
      f[key] is Map ? f[key] as Map : const {};
  // security.sandbox / security.asks, access.logout; plan_limits.home_env
  // and .store, newer than its rpc and argv: an add-on signed with the
  // earlier table gets them from the app's own adapter.
  for (final (group, key) in [
    ('security', 'sandbox'),
    ('security', 'asks'),
    ('access', 'logout'),
    ('plan_limits', 'home_env'),
    ('plan_limits', 'store'),
  ]) {
    final mine = table(merged, group), theirs = table(own, group);
    if (_emptyFact(mine[key]) && !_emptyFact(theirs[key])) {
      merged[group] = {...mine, key: theirs[key]};
    }
  }
  // research: the app's own when the add-on has none, answers only in text
  // where the app's answers in its format, or puts the prompt into argv.
  final mine = table(merged, 'research'), theirs = table(own, 'research');
  final mineArgv = mine['argv'] is List ? mine['argv'] as List : const [];
  final ownArgv = theirs['argv'] is List ? theirs['argv'] as List : const [];
  if (mineArgv.isEmpty && ownArgv.isNotEmpty ||
      (mine['output'] ?? 'text') == 'text' &&
          (theirs['output'] ?? 'text') != 'text' &&
          ownArgv.isNotEmpty ||
      mineArgv.contains('{prompt}') &&
          ownArgv.isNotEmpty &&
          !ownArgv.contains('{prompt}')) {
    if (theirs.isNotEmpty) merged['research'] = theirs;
  }
  return merged;
}

/// flutter_addons.AdapterRegistry: the add-ons found, verified and (switched
/// on) loaded; the agents and providers they bring replace the built-in ones.
final class AddonRegistry {
  AddonRegistry(this.verifier, this.dirs);
  final AddonVerifier verifier;
  final List<String> dirs; // the user's folder first, then the system's
  List<Addon> items = [];
  List<Adapter> adapters = builtinAdapters();

  /// addons.find: an id in the user folder wins over the system's.
  List<String> find() {
    final seen = <String>{}, found = <String>[];
    for (final base in dirs) {
      List<String> entries;
      try {
        entries = [
          for (final e in Directory(base).listSync(followLinks: false))
            if (!seen.contains(p.basename(e.path))) e.path,
        ]..sort();
      } on FileSystemException {
        continue;
      }
      for (final path in entries.take(100)) {
        seen.add(p.basename(path));
        found.add(path);
      }
    }
    return found;
  }

  /// Whether this core can take a verified add-on as data: its code (if
  /// any) is code the core has built in.
  static String? dataOnlyRefusal(Addon addon) {
    if (!addon.bringsCode) return null;
    final providerKeys = {for (final x in providerFactsAll()) x};
    if (addon.kind == 'provider' &&
        addon.files.containsKey('addon.py') &&
        addon.provides.every(providerKeys.contains)) {
      return null;
    }
    if (addon.kind == 'agent' &&
        !addon.files.containsKey('addon.py') &&
        addon.provides.every(builtInHooks.contains)) {
      return null;
    }
    return 'brings code; this Maprisma takes add-ons as data only: needs an update';
  }

  void reload(Set<String> enabled) {
    items = [for (final folder in find()) verifier.verify(folder)];
    for (final item in items) {
      if (item.state != 'verified') continue;
      final refusal = dataOnlyRefusal(item);
      if (refusal != null) _refuse(item, refusal);
    }
    final verified = items.where((i) => i.state == 'verified').toList();
    final hiddenAgents = {
      for (final i in verified)
        if (i.kind == 'agent') ...i.provides,
    };
    addedProviders.clear();
    hiddenProviders
      ..clear()
      ..addAll({
        for (final i in verified)
          if (i.kind == 'provider') ...i.provides,
      });
    final builtIn = builtinAdapters();
    final added = <Adapter>[];
    for (final item in verified) {
      if (!supportedKinds.contains(item.kind) || !enabled.contains(item.id)) {
        continue;
      }
      try {
        if (item.kind == 'agent') {
          final source = utf8.decode(item.files['agent.toml']!);
          final parsed = Adapter.parse(source);
          final own = builtIn
              .where((a) => a.command == parsed.command)
              .firstOrNull;
          if (added.any((a) => a.command == parsed.command) ||
              builtIn.any(
                (a) =>
                    a.command == parsed.command &&
                    !hiddenAgents.contains(a.command),
              )) {
            throw const FormatException('the agent exists already');
          }
          added.add(Adapter(withNewerFacts(parsed.facts, own?.facts)));
        } else {
          for (final key in item.provides) {
            if (!addedProviders.contains(key)) addedProviders.add(key);
          }
        }
        item.state = 'loaded';
      } catch (error) {
        item
          ..state = 'failed'
          ..reason = '$error';
      }
    }
    int order(Adapter a) {
      final i = agentOrder.indexOf(a.command);
      return i < 0 ? agentOrder.length : i;
    }

    final sortedAdded = [...added];
    mergeSort(sortedAdded, order);
    adapters = [
      ...builtIn.where((a) => !hiddenAgents.contains(a.command)),
      ...sortedAdded,
    ];
  }

  /// flutter_addons.snapshot (sign-ins come from the caller).
  Map<String, dynamic> snapshot(
    Set<String> enabled,
    List<Map<String, dynamic>> Function(Addon) signIns,
    String userDir,
  ) => {
    'addons': [
      for (final item in items)
        {
          'id': item.id,
          'name': item.name.isEmpty ? item.id : item.name,
          'version': item.version,
          'summary': item.summary,
          'description': item.description,
          'kind': item.kind,
          'state': item.state,
          'enabled': enabled.contains(item.id),
          'loaded': item.state == 'loaded',
          'supported': supportedKinds.contains(item.kind),
          'verified': const {
            'verified',
            'loaded',
            'failed',
          }.contains(item.state),
          'reads': item.reads,
          'sends': item.sends,
          'privacy': item.privacy,
          'capabilities': item.capabilities,
          'provides': item.provides,
          'sign_ins': signIns(item),
          'legacy': item.reason == legacyReason,
          'removable':
              p.dirname(item.folder) == userDir &&
              FileSystemEntity.typeSync(item.folder, followLinks: false) !=
                  FileSystemEntityType.link,
        },
    ],
  };
}

/// A stable sort (sorted() with a key).
void mergeSort<T>(List<T> list, int Function(T) key) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) {
    final c = key(a.$2).compareTo(key(b.$2));
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].$2;
  }
}
