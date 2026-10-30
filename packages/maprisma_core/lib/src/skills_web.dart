import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'mcp_catalog.dart' show quoteUrl, urlencode;
import 'model_hub.dart' show netFetch, FetchError;
import 'posix_ffi.dart';
import 'line_diff.dart' show pySplitlines;
import 'py_values.dart';

/// skills_web: find skills on the web (the skills.sh directory) and fetch
/// one, without running anything. The search names the skill, its GitHub
/// repository and how often it was installed; its folder comes from GitHub's
/// file list (one request), its files from raw.githubusercontent.com, at most
/// [maxFiles] files and [maxTotal] bytes, no links, no paths leaving the
/// folder. Fetched files wait in a private staging folder; the plan names
/// them with their SHA-256 and the worker writes them (preview, backup, Undo).

const skillsSearch = 'https://skills.sh/api/search';
const skillsTimeout = 20;
const maxFiles = 150;
const maxFile = 5 * 1024 * 1024;
const maxTotal = 30 * 1024 * 1024;
const sharedSkills = '~/.agents/skills';
final repoRe = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$',
);
final skillIdRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$');
final _part = RegExp(r'^[A-Za-z0-9_.@+ -]{1,120}$');
const _scripts = ['.py', '.sh', '.js', '.ts', '.rb', '.pl'];

String _cut(String text, int limit) {
  final runes = text.runes;
  return runes.length <= limit ? text : String.fromCharCodes(runes.take(limit));
}

String treeUrl(String repo) =>
    'https://api.github.com/repos/$repo/git/trees/HEAD?recursive=1';
String rawUrl(String repo, String path) =>
    'https://raw.githubusercontent.com/$repo/HEAD/${quoteUrl(path)}';

/// skills_web._get: only the three fixed hosts, no redirects.
Future<List<int>> _get(
  String url,
  int limit, [
  String accept = 'application/json',
]) async {
  const allowed = [
    'https://skills.sh/api/',
    'https://api.github.com/repos/',
    'https://raw.githubusercontent.com/',
  ];
  if (!allowed.any(url.startsWith)) {
    throw const FormatException('not an address this page fetches');
  }
  try {
    return await netFetch(
      url,
      maxBytes: limit,
      timeout: skillsTimeout,
      redirects: 0,
      headers: {'Accept': accept},
    );
  } on FetchError catch (error) {
    throw FormatException(error.message);
  }
}

/// skills_web.parse_search.
List<Map<String, dynamic>> parseSkillSearch(dynamic data) {
  final found = <Map<String, dynamic>>[];
  final items = data is Map ? data['skills'] : null;
  for (final item in items is List ? items : const []) {
    if (item is! Map) continue;
    final repo = pyStr(item['source'] ?? ''), id = pyStr(item['skillId'] ?? '');
    if (repoRe.hasMatch(repo) && skillIdRe.hasMatch(id)) {
      final installs = item['installs'];
      found.add({
        'name': _cut(pyTruthy(item['name']) ? pyStr(item['name']) : id, 100),
        'skill_id': id,
        'repo': repo,
        'installs': installs is int ? installs : 0,
      });
    }
  }
  return found;
}

/// skills_web.search on skills.sh.
Future<List<Map<String, dynamic>>> searchSkills(
  String query, {
  int limit = 30,
  Future<List<int>> Function(String url, int limit, String accept)? get,
}) async {
  final params = urlencode({'q': _cut(query.trim(), 100), 'limit': limit});
  final body = await (get ?? _get)(
    '$skillsSearch?$params',
    2 * 1024 * 1024,
    'application/json',
  );
  return parseSkillSearch(jsonDecode(utf8.decode(body)));
}

String _secondLast(String path) {
  final parts = path.split('/');
  return parts[parts.length - 2];
}

/// skills_web.files_of: (folder in the repository, [(path inside the skill,
/// repo path, size, executable)]); FormatException when it is not there or
/// too big.
(String, List<(String, String, int, bool)>) skillFiles(
  dynamic tree,
  String skillId,
) {
  final entries = tree is Map ? tree['tree'] : null;
  if (entries is! List) throw const FormatException('no file list');
  var folders = [
    for (final e in entries)
      if (e is Map &&
          e['path'] is String &&
          e['type'] == 'blob' &&
          (e['path'] as String).endsWith('/SKILL.md') &&
          _secondLast(e['path'] as String) == skillId)
        (e['path'] as String).substring(
          0,
          (e['path'] as String).length - '/SKILL.md'.length,
        ),
  ];
  if (folders.isEmpty &&
      entries.any((e) => e is Map && e['path'] == 'SKILL.md')) {
    folders = ['']; // a repository that is one skill
  }
  if (folders.isEmpty) {
    throw FormatException('no folder $skillId with a SKILL.md');
  }
  var folder = folders.first;
  for (final f in folders) {
    if (f.length < folder.length) folder = f;
  }
  final prefix = folder.isEmpty ? '' : '$folder/';
  final files = <(String, String, int, bool)>[];
  var total = 0;
  for (final entry in entries) {
    final path = entry is Map && entry['path'] is String
        ? entry['path'] as String
        : '';
    if (!path.startsWith(prefix) || (entry as Map)['type'] != 'blob') continue;
    if (!const ['100644', '100755'].contains(entry['mode'])) {
      continue; // links and submodules stay out
    }
    final inner = path.substring(prefix.length);
    final parts = inner.split('/');
    if (parts.any(
          (x) => x.isEmpty || x == '.' || x == '..' || !_part.hasMatch(x),
        ) ||
        parts.length > 8) {
      continue;
    }
    final size = entry['size'] is int ? entry['size'] as int : maxFile + 1;
    if (size > maxFile) throw FormatException('$inner is too large');
    total += size;
    files.add((inner, path, size, entry['mode'] == '100755'));
  }
  if (files.length > maxFiles || total > maxTotal) {
    throw const FormatException('the skill is too large');
  }
  if (!files.any((f) => f.$1 == 'SKILL.md')) {
    throw const FormatException('no SKILL.md');
  }
  return (folder, files);
}

/// skills_ctl.description on a SKILL.md's text (its first 16 KiB).
String skillDescription(String text) {
  final head = _cut(text, 16 * 1024);
  final front = RegExp(r'^---\s*\n(.*?)\n---', dotAll: true).firstMatch(head);
  if (front == null) return '';
  final lines = pySplitlines(front[1]!);
  for (var index = 0; index < lines.length; index++) {
    final found = RegExp(r'^description:\s*(.*)$').firstMatch(lines[index]);
    if (found == null) continue;
    var value = found[1]!.trim();
    if (const ['', '>', '|', '>-', '|-', '>+', '|+'].contains(value)) {
      final more = <String>[];
      for (final following in lines.skip(index + 1)) {
        if (following.isNotEmpty && following[0].trim().isNotEmpty) break;
        more.add(following.trim());
      }
      value = more.where((m) => m.isNotEmpty).join(' ');
    }
    value = value.trim().replaceAll(RegExp(r'''^['"]+|['"]+$'''), '');
    return _cut(value, 300) + (value.runes.length > 300 ? '…' : '');
  }
  return '';
}

/// skills_web.fetch into a private staging folder: the skill's files, each
/// as a numbered file there, with what the plan needs to name them.
Future<Map<String, dynamic>> fetchSkill(
  String repo,
  String skillId,
  String stagingRoot,
  Posix posix, {
  Future<List<int>> Function(String url, int limit, String accept)? get,
  DateTime? now,
}) async {
  if (!repoRe.hasMatch(repo) || !skillIdRe.hasMatch(skillId)) {
    throw const FormatException('Invalid skill');
  }
  final fetch = get ?? _get;
  final tree = jsonDecode(
    utf8.decode(
      await fetch(
        treeUrl(repo),
        8 * 1024 * 1024,
        'application/vnd.github+json',
      ),
    ),
  );
  final (_, files) = skillFiles(tree, skillId);
  _sweep(stagingRoot, now ?? DateTime.now());
  final random = Random.secure();
  final folder = p.join(
    stagingRoot,
    [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join(),
  );
  final staged = <List<dynamic>>[];
  var description = '';
  for (final (index, (inner, path, size, executable)) in files.indexed) {
    final data = await fetch(rawUrl(repo, path), max(size, 1) + 1024, '*/*');
    final file = p.join(folder, '$index');
    posix.atomicWrite(file, data);
    staged.add([inner, file, sha256.convert(data).toString(), executable]);
    if (inner == 'SKILL.md') {
      description = skillDescription(
        utf8.decode(data.take(16384).toList(), allowMalformed: true),
      );
    }
  }
  return {
    'repo': repo,
    'skill_id': skillId,
    'files': staged,
    'description': description,
    'scripts': [
      for (final f in files)
        if (_scripts.any(f.$1.endsWith)) f.$1,
    ],
  };
}

/// Staging folders older than an hour go (a preview lives ten minutes).
void _sweep(String root, DateTime now) {
  try {
    for (final entry in Directory(root).listSync(followLinks: false)) {
      if (entry is Directory &&
          now.difference(entry.statSync().modified).inMinutes >= 60) {
        entry.deleteSync(recursive: true);
      }
    }
  } on FileSystemException {
    // Nothing staged yet.
  }
}

/// The staged files of a plan read back for writing: inside the staging
/// root, this account's regular files, the size and SHA-256 reviewed.
List<(String, List<int>, bool)> readStaged(
  List<(String, String, String, bool)> staged,
  String stagingRoot,
  Posix posix,
) {
  final root = p.normalize(stagingRoot);
  var total = 0;
  return [
    for (final (target, file, digest, executable) in staged)
      () {
        if (!p.isWithin(root, p.normalize(file))) {
          throw StateError('A fetched file is not where it was staged');
        }
        final data = posix.readChecked(
          file,
          (fd, size) => size > maxFile ? null : posix.readAt(fd, 0, size),
        );
        if (data == null || sha256.convert(data).toString() != digest) {
          throw StateError('A fetched file changed; fetch it again');
        }
        total += data.length;
        if (total > maxTotal) throw StateError('the skill is too large');
        return (target, data as List<int>, executable);
      }(),
  ];
}

/// Fetched skills behind opaque, expiring handles: the app sees the name,
/// the description, the files and the scripts; the staged paths stay here.
final class WebSkills {
  WebSkills(this.newToken);
  final String Function() newToken;
  final items = <String, (DateTime, Map<String, dynamic>)>{};
  static const keep = Duration(minutes: 30);

  Map<String, dynamic> register(Map<String, dynamic> fetched, String name) {
    final now = DateTime.now();
    items.removeWhere((_, v) => now.difference(v.$1) >= keep);
    while (items.length >= 16) {
      items.remove(items.keys.first);
    }
    final token = newToken();
    items[token] = (now, fetched);
    return {
      'fetched': token,
      'name': name,
      'repo': fetched['repo'],
      'skill_id': fetched['skill_id'],
      'description': fetched['description'],
      'files': [for (final f in fetched['files'] as List) f[0]],
      'scripts': fetched['scripts'],
    };
  }

  Map<String, dynamic> get(dynamic token) {
    final kept = token is String ? items[token] : null;
    if (kept == null || DateTime.now().difference(kept.$1) >= keep) {
      throw const FormatException('Fetch the skill again');
    }
    return kept.$2;
  }
}
