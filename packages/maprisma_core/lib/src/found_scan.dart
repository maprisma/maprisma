import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'desktop.dart' show whichIn;
import 'installers.dart' show folderBytes, runWithDiskBudget;
import 'posix_ffi.dart';
import 'scan_files.dart' show headEntries;

/// mcp_scan and skills_scan: programs on this PC that offer an MCP server
/// and skill sets apps brought along, found without running anything. A
/// program counts when its file holds the MCP protocol's own words; how to
/// start it comes from its own usage text, read from the file too. AppImages
/// are only read from what an earlier look inside them kept (the cache).

const _markers = [
  'notifications/initialized',
  'protocolVersion',
  'tools/list',
  'modelcontextprotocol',
];

/// Programs that use MCP servers or run them, never offered as one; the
/// agents' commands and the local LLMs' programs come on top.
const mcpClients = {
  'lms', 'node', 'bun', 'deno', 'python', 'python3', 'uv', 'uvx', 'npx', //
  'npm', 'docker', 'podman', 'code', 'cursor', 'zed', 'ai-agents-map-toggle',
  'chromium', 'chrome', 'firefox', 'electron',
};

/// The local LLMs' own programs (llm_engine programs of the built-ins).
const llmPrograms = {
  'llamacpp': ['llama-server'],
  'ollama': ['ollama'],
  'jan': ['jan-llama-worker', 'jan-llama-worke'],
};

const maxBytes = 400 * 1024 * 1024, _chunk = 8 * 1024 * 1024;
const _usageSpan = 900, _overlap = 2048;
const _folders = [
  (r'photo|image|pic|paint|draw|vector|design|fig|light', 'Pictures'),
  (r'film|video|movie|effect', 'Videos'),
  (r'sound|audio|music', 'Music'),
];

/// Python's bytes.strip(): ASCII white space only.
String _strip(String s) {
  const ws = ' \t\n\r\x0b\x0c';
  var a = 0, b = s.length;
  while (a < b && ws.contains(s[a])) {
    a++;
  }
  while (b > a && ws.contains(s[b - 1])) {
    b--;
  }
  return s.substring(a, b);
}

bool _wordish(int c) =>
    c >= 0x30 && c <= 0x39 ||
    c >= 0x41 && c <= 0x5a ||
    c >= 0x61 && c <= 0x7a ||
    c == 0x5f ||
    c == 0x2e ||
    c == 0x2d;

/// After "mcp" at [i]: one or more spaces, then "[" (its index, or -1).
int _bracketAfter(String data, int i) {
  var j = i + 3;
  if (j >= data.length || data.codeUnitAt(j) != 0x20) return -1;
  while (j < data.length && data.codeUnitAt(j) == 0x20) {
    j++;
  }
  return j < data.length && data.codeUnitAt(j) == 0x5b ? j : -1;
}

/// The leftmost match of `[\w.-]{1,64} mcp +\[` (searched by its literal
/// part: a regular expression over megabytes is slow): later " mcp"s can't
/// start earlier, as a space ends the run before them.
int _firstUsage(String data) {
  for (var i = data.indexOf(' mcp'); i >= 0; i = data.indexOf(' mcp', i + 1)) {
    if (_bracketAfter(data, i + 1) < 0) continue;
    var k = i;
    while (k > 0 && i - k < 64 && _wordish(data.codeUnitAt(k - 1))) {
      k--;
    }
    if (k < i) return k;
  }
  return -1;
}

/// The leftmost match of `mcp +\[--[a-z]`.
int _secondUsage(String data) {
  for (var i = data.indexOf('mcp '); i >= 0; i = data.indexOf('mcp ', i + 1)) {
    final j = _bracketAfter(data, i);
    if (j >= 0 &&
        j + 3 < data.length &&
        data.codeUnitAt(j + 1) == 0x2d &&
        data.codeUnitAt(j + 2) == 0x2d &&
        data.codeUnitAt(j + 3) >= 0x61 &&
        data.codeUnitAt(j + 3) <= 0x7a) {
      return i;
    }
  }
  return -1;
}

final _subcommand = RegExp(r'^[ \t\n\r\f\v]+[\w.-]+ \w');

/// _scan_bytes: (how many markers, the MCP usage block) from [read], which
/// gives the file's next bytes (empty at its end). Strings hold one byte per
/// character (latin-1), as Python's bytes do.
(int, String) scanBytes(List<int> Function() read, String name) {
  final seen = <String>{};
  String? firstHit, secondHit;
  var automation = false, serverText = false;
  var tail = '';
  var chunk = latin1.decode(read());
  while (chunk.isNotEmpty) {
    final following = latin1.decode(read());
    final data = tail + chunk;
    final last = following.isEmpty;
    chunk = following;
    for (final m in _markers) {
      if (!seen.contains(m) && data.contains(m)) seen.add(m);
    }
    automation = automation || data.contains('--automation-read-root');
    serverText = serverText || data.contains('MCP server');
    final usable = last ? data.length : data.length - _usageSpan;
    if (firstHit == null) {
      final start = _firstUsage(data);
      if (start >= 0 && start < usable) {
        firstHit = data.substring(
          start,
          math.min(data.length, start + _usageSpan),
        );
      }
    }
    if (firstHit == null && secondHit == null) {
      final start = _secondUsage(data);
      if (start >= 0 && start < usable) {
        secondHit = data.substring(
          start,
          math.min(data.length, start + _usageSpan),
        );
      }
    }
    tail = data.length > _overlap
        ? data.substring(data.length - _overlap)
        : data;
  }
  var count = seen.length;
  var usage = '';
  final block = firstHit ?? secondHit;
  if (block != null) {
    // The mcp usage: its first line and the indented lines after it.
    final lines = block.split('\n');
    final kept = [lines.first];
    for (final line in lines.skip(1)) {
      if (!line.startsWith('   ') ||
          _subcommand.hasMatch(line) && !line.contains('--')) {
        break;
      }
      kept.add(_strip(line));
    }
    usage = kept.join(' ').split('\x00').first;
    if (usage.length > 600) usage = usage.substring(0, 600);
  }
  if (usage.isEmpty && count >= 2 && automation) {
    // A usage text made when the program runs (clap): its root options stay.
    usage = 'mcp [--automation-read-root DIR] [--automation-write-root DIR]';
  }
  if (usage.isEmpty && serverText && name.toLowerCase().contains('mcp')) {
    count = math.max(count, 1);
  }
  return (count, usage);
}

String _decode(String bytes) =>
    utf8.decode(latin1.encode(bytes), allowMalformed: true);

/// mcp_scan.Candidate.
final class Candidate {
  Candidate(
    this.name,
    this.program,
    this.command, {
    this.usage = '',
    this.appimage = '',
    this.configured = const [],
    this.sure = true,
    this.inner = '',
  });
  final String name, program, usage, appimage, inner;
  final List<String> command, configured;
  final bool sure;
  String version = '', updateFrom = '';
  final replaces = <String>[], oldFolders = <String>[], users = <String>[];

  Map<String, dynamic> toJson() => {
    'name': name,
    'program': program,
    'command': command,
    'usage': usage,
    'appimage': appimage,
    'configured': configured,
    'sure': sure,
    'inner': inner,
    'version': version,
    'update_from': updateFrom,
    'replaces': replaces,
    'old_folders': oldFolders,
    'users': users,
  };
}

/// skills_scan.SkillSet.
typedef SkillSet = ({String path, List<String> skills, String origin});

final class FoundScan {
  FoundScan(
    this.home, {
    required this.cacheFile,
    this.searchPath,
    this.opt = '/opt',
    this.tempDir = '',
    this.mcpFolders = const [],
    this.skillFolders = const [],
    List<(String, int)>? skillRoots,
    Posix? posix,
  }) : skillRoots = skillRoots ?? defaultSkillRoots(home),
       posix = posix ?? Posix();

  final String home, cacheFile, opt;

  /// Where an AppImage's usr/bin is unpacked to look inside (removed after).
  final String tempDir;
  final String? searchPath;

  /// Setup's added folders (extra_folders, ~-paths as stored).
  final List<String> mcpFolders, skillFolders;
  final List<(String, int)> skillRoots;
  final Posix posix;

  static List<(String, int)> defaultSkillRoots(String home) => [
    ('/usr/share', 4),
    ('/usr/local/share', 4),
    ('/opt', 5),
    (p.join(home, 'Applications'), 6),
    (p.join(home, '.local/share'), 4),
    (p.join(home, '.local/lib/node_modules'), 4),
    ('/usr/lib/node_modules', 4),
    (p.join(home, '.claude/plugins'), 6),
  ];

  // --- small helpers --------------------------------------------------------

  /// scandir_head: at most [limit] entries, in the folder's own order.
  List<FileSystemEntity> _head(String folder, int limit) {
    if (folder.isEmpty) throw const FileSystemException('no folder');
    // Read one entry at a time up to the bound (never the whole folder first).
    return headEntries(p.absolute(folder), limit, posix);
  }

  static FileStat? _stat(String path) {
    final st = FileStat.statSync(path);
    return st.type == FileSystemEntityType.notFound ? null : st;
  }

  static bool _isFile(String path) =>
      _stat(path)?.type == FileSystemEntityType.file;
  static bool _isDir(String path) =>
      _stat(path)?.type == FileSystemEntityType.directory;
  static bool _isLink(String path) => FileSystemEntity.isLinkSync(path);
  static bool _executable(String path) {
    final st = _stat(path);
    return st != null && st.mode & 0x49 != 0;
  }

  /// Path.resolve(): links followed as far as they go.
  static String resolve(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      var current = p.normalize(p.absolute(path));
      for (var i = 0; i < 40 && _isLink(current); i++) {
        try {
          final target = Link(current).targetSync();
          current = p.normalize(
            p.isAbsolute(target) ? target : p.join(p.dirname(current), target),
          );
        } on FileSystemException {
          break;
        }
      }
      return current;
    }
  }

  String _expand(String path) => path == '~'
      ? home
      : path.startsWith('~/')
      ? p.join(home, path.substring(2))
      : path;

  /// extra_folders.folders: the added folders that are there now.
  List<String> _added(List<String> saved) {
    final found = <String>[];
    for (final text in saved.where((t) => t.trim().isNotEmpty).take(50)) {
      final path = p.normalize(_expand(text));
      if (p.isAbsolute(path) && _isDir(path) && !found.contains(path)) {
        found.add(path);
      }
    }
    return found;
  }

  bool _elfOrScript(String path) {
    try {
      final fd = posix.openAt(-100, path, Posix.nonBlock);
      final List<int> head;
      try {
        head = posix.readPrefix(fd, 4);
      } finally {
        posix.close(fd);
      }
      return head.length >= 4 &&
              head[0] == 0x7f &&
              head[1] == 0x45 &&
              head[2] == 0x4c &&
              head[3] == 0x46 ||
          head.length >= 2 && head[0] == 0x23 && head[1] == 0x21;
    } on Object {
      return false;
    }
  }

  // --- the scan cache --------------------------------------------------------

  Map<String, dynamic>? _cacheData;
  Map<String, dynamic> get cache {
    if (_cacheData != null) return _cacheData!;
    try {
      final data = jsonDecode(
        utf8.decode(posix.readRegular(cacheFile, 4000000)),
      );
      _cacheData = data is Map<String, dynamic> ? data : {};
    } on Object {
      _cacheData = {};
    }
    return _cacheData!;
  }

  void saveCache() {
    final data = _cacheData;
    if (data == null) return;
    final kept = data.entries.toList();
    final tail = kept.skip(math.max(0, kept.length - 2000));
    try {
      Directory(p.dirname(cacheFile)).createSync(recursive: true);
      posix.atomicWrite(
        cacheFile,
        utf8.encode(jsonEncode({for (final e in tail) e.key: e.value})),
      );
    } on Object {
      // not kept: read again next time
    }
  }

  /// scan_file: (how many markers, the MCP usage) of a file, kept per file
  /// (size, time) in the cache.
  (int, String) scanFile(String path, {bool keep = true}) {
    final st = _stat(path);
    if (st == null) return (0, '');
    final key =
        '$path|${st.size}|${st.modified.millisecondsSinceEpoch ~/ 1000}';
    final kept = keep ? cache[key] : null;
    if (kept is List && kept.length == 2) {
      return (kept[0] as int, latin1.decode(utf8.encode('${kept[1]}')));
    }
    if (st.size > maxBytes || st.size == 0) return (0, '');
    (int, String) found;
    try {
      final fd = posix.openAt(-100, path, Posix.nonBlock);
      try {
        final info = posix.stat(fd);
        if (info.mode & 0xf000 != 0x8000) return (0, '');
        final size = math.min(info.size, maxBytes);
        var done = 0;
        found = scanBytes(() {
          if (done >= size) return const <int>[];
          final chunk = posix.readAt(fd, done, math.min(_chunk, size - done));
          done += chunk.length;
          return chunk;
        }, p.basename(path));
      } finally {
        posix.close(fd);
      }
    } on Object {
      return (0, '');
    }
    if (keep) cache[key] = [found.$1, _decode(found.$2)];
    return found;
  }

  // --- where to look ---------------------------------------------------------

  List<String> _executables(String folder, [int depth = 0]) {
    final found = <String>[];
    List<String> entries;
    try {
      entries = [for (final e in _head(folder, 500)) e.path]..sort();
    } on FileSystemException {
      return found;
    }
    for (final entry in entries) {
      if (_isFile(entry) && _executable(entry)) {
        found.add(entry);
      } else if (depth > 0 && _isDir(entry) && !_isLink(entry)) {
        found.addAll(_executables(entry, depth - 1));
      }
    }
    return found;
  }

  List<String> ownPrograms() {
    final added = _added(mcpFolders);
    final places = [p.join(home, '.local/bin'), p.join(home, 'bin')];
    for (final folder in added) {
      places.addAll([folder, p.join(folder, 'bin'), p.join(folder, 'usr/bin')]);
    }
    for (final root in [p.join(home, 'Applications'), opt, ...added]) {
      List<String> apps;
      try {
        apps = [
          for (final e in _head(root, 1000))
            if (_isDir(e.path)) e.path,
        ]..sort();
      } on FileSystemException {
        continue;
      }
      for (final app in apps.take(100)) {
        places.addAll([p.join(app, 'usr/bin'), p.join(app, 'bin'), app]);
      }
    }
    return [
      for (final place in places)
        for (final x in _executables(place))
          if (!p.basename(x).toLowerCase().endsWith('.appimage')) x,
    ];
  }

  List<String> pathPrograms() {
    final found = <String>[];
    for (final folder in (searchPath ?? '').split(':')) {
      try {
        found.addAll(
          [
            for (final e in _head(folder, 20000))
              if (p.basename(e.path).toLowerCase().contains('mcp')) e.path,
          ].take(50),
        );
      } on FileSystemException {
        continue;
      }
    }
    return found;
  }

  List<String> appimages() {
    final found = <String>[];
    for (final folder in [
      p.join(home, 'Applications'),
      p.join(home, '.local/bin'),
      ..._added(mcpFolders),
    ]) {
      try {
        found.addAll(
          ([
            for (final e in _head(folder, 5000))
              if (p.basename(e.path).toLowerCase().endsWith('.appimage') &&
                  _isFile(e.path) &&
                  _executable(e.path))
                e.path,
          ]..sort()).take(100),
        );
      } on FileSystemException {
        continue;
      }
    }
    return found;
  }

  static String appimageStem(String path) {
    final stem = p
        .basename(path)
        .replaceFirst(RegExp(r'\.appimage$', caseSensitive: false), '');
    return stem.replaceFirst(
      RegExp(
        r'[-_.](linux|x86_64|amd64|aarch64|arm64|x64)([-_.](x86_64|amd64|aarch64|arm64))?$',
        caseSensitive: false,
      ),
      '',
    );
  }

  static final _versionRe = RegExp(r'^(.+?)[-_]v?(\d+(?:\.\d+)+)$');

  /// app_version: "gridcraft-0.7.0" → ("gridcraft", [0, 7, 0]).
  static (String, List<int>)? appVersion(String stem) {
    final hit = _versionRe.firstMatch(stem);
    if (hit == null) return null;
    return (
      hit[1]!.toLowerCase(),
      [for (final x in hit[2]!.split('.')) int.parse(x)],
    );
  }

  static int compareVersions(List<int> a, List<int> b) {
    for (var i = 0; i < math.min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return a.length.compareTo(b.length);
  }

  Map<String, List<List<int>>> _unpackedVersions() {
    final found = <String, List<List<int>>>{};
    List<String> folders;
    try {
      folders = [
        for (final e in _head(p.join(home, 'Applications'), 5000))
          if (_isDir(e.path) && !p.basename(e.path).startsWith('.')) e.path,
      ];
    } on FileSystemException {
      return found;
    }
    for (final folder in folders.take(200)) {
      final info = appVersion(p.basename(folder));
      if (info != null) found.putIfAbsent(info.$1, () => []).add(info.$2);
    }
    return found;
  }

  Map<String, List<List<int>>> _lookedIntoVersions() {
    final found = <String, List<List<int>>>{};
    for (final key in cache.keys) {
      if (key.startsWith('appimage:')) {
        final info = appVersion(
          appimageStem(key.substring('appimage:'.length).split('|').first),
        );
        if (info != null) found.putIfAbsent(info.$1, () => []).add(info.$2);
      }
    }
    return found;
  }

  String? _imageKey(String path) {
    final st = _stat(path);
    if (st == null) return null;
    return 'appimage:$path|${st.size}|${st.modified.millisecondsSinceEpoch ~/ 1000}';
  }

  /// looked_into: what a look inside this AppImage found, null if never.
  List<(String, int, String)>? lookedInto(String path) {
    final key = _imageKey(path);
    final found = key == null ? null : cache[key];
    if (found is! List) return null;
    return [
      for (final item in found)
        if (item is List && item.length == 3)
          ('${item[0]}', item[1] as int, '${item[2]}'),
    ];
  }

  /// not_looked_into: AppImages never looked inside, nor unpacked by hand.
  List<String> notLookedInto() {
    Set<String> extracted;
    try {
      extracted = {
        for (final e in _head(p.join(home, 'Applications'), 5000))
          if (_isDir(e.path)) p.basename(e.path),
      };
    } on FileSystemException {
      extracted = {};
    }
    return [
      for (final i in appimages())
        if (!extracted.contains(appimageStem(i)) && lookedInto(i) == null) i,
    ];
  }

  /// new_versions_found: AppImages not looked into that are newer versions
  /// of apps looked into or unpacked before (only named, nothing run).
  List<String> newVersionsFound() {
    final known = _unpackedVersions();
    for (final e in _lookedIntoVersions().entries) {
      known.putIfAbsent(e.key, () => []).addAll(e.value);
    }
    return [
      for (final image in notLookedInto())
        if (appVersion(appimageStem(image)) case final info?)
          if ((known[info.$1] ?? const []).any(
            (v) => compareVersions(v, info.$2) < 0,
          ))
            image,
    ];
  }

  // --- looking inside AppImages (the user's click) ---------------------------

  static const maxBinBytes = 2 * 1024 * 1024 * 1024;
  static const maxAppBytes = 10 * 1024 * 1024 * 1024;

  /// extract_argv: --appimage-extract runs the AppImage's own program, so it
  /// runs closed in (bubblewrap): no network, no home folder, the system's
  /// /usr read-only, the AppImage read-only and only the work folder
  /// writable. Without bwrap nothing is unpacked.
  List<String> extractArgv(
    String appimage,
    String work, [
    List<String> pattern = const [],
  ]) {
    final bwrap = whichIn('bwrap', searchPath);
    if (bwrap == null) {
      throw StateError(
        'unpacking an AppImage needs bubblewrap (bwrap), which keeps it from touching anything else; install bubblewrap',
      );
    }
    return [
      bwrap, '--unshare-all', '--die-with-parent', '--new-session', //
      '--clearenv', '--ro-bind', '/usr', '/usr', '--symlink', 'usr/lib',
      '/lib', '--symlink', 'usr/lib64', '/lib64', '--symlink', 'usr/bin',
      '/bin', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp',
      '--ro-bind', appimage, '/in/app.AppImage', '--bind', work, '/out',
      '--chdir', '/out', '--', '/in/app.AppImage', '--appimage-extract',
      ...pattern,
    ];
  }

  static void _rmtree(String path) {
    try {
      Directory(path).deleteSync(recursive: true);
    } on FileSystemException {
      // ignore_errors
    }
  }

  /// unpack_bin: usr/bin of an AppImage in a new private temporary folder:
  /// (that folder, its usr/bin). The caller removes the folder.
  Future<(String, String)> unpackBin(String path) async {
    Directory(tempDir).createSync(recursive: true);
    posix.chmodPath(tempDir, 0x1c0);
    final work = Directory(tempDir).createTempSync('appimage-').path;
    try {
      final ok = await runWithDiskBudget(
        extractArgv(path, work, ['usr/bin/*']),
        work,
        maxBinBytes,
        const Duration(seconds: 60),
      );
      final folder = p.join(work, 'squashfs-root/usr/bin');
      if (!ok ||
          !_isDir(folder) ||
          folderBytes(work, maxBinBytes) > maxBinBytes) {
        throw StateError('could not look inside ${p.basename(path)}');
      }
      return (work, folder);
    } catch (_) {
      _rmtree(work); // nothing of a failed look stays
      rethrow;
    }
  }

  /// look_inside: each AppImage's programs read once (unpacked to a
  /// temporary folder that is removed right after), kept in the cache.
  Future<Map<String, List<List<Object>>>> lookInside(List<String> paths) async {
    final results = <String, List<List<Object>>>{};
    for (final path in paths) {
      final key = _imageKey(path);
      if (key == null) continue;
      final found = <List<Object>>[];
      String work, folder;
      try {
        (work, folder) = await unpackBin(path);
      } on StateError {
        cache[key] = <Object>[];
        continue;
      } on FileSystemException {
        cache[key] = <Object>[];
        continue;
      }
      try {
        for (final program in _executables(folder)) {
          if (!_isLink(program) && _elfOrScript(program)) {
            final (count, usage) = scanFile(program, keep: false);
            found.add([p.basename(program), count, _decode(usage)]);
          }
        }
      } finally {
        _rmtree(work);
      }
      cache[key] = found;
      results[path] = found;
    }
    saveCache();
    return results;
  }

  /// unpack: a whole AppImage into `~/Applications/<app>-<version>/`, for a
  /// server that lives in it. Returns that folder.
  Future<String> unpack(String appimage) async {
    final into = p.join(home, 'Applications', appimageStem(appimage));
    if (FileSystemEntity.typeSync(into, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return into;
    }
    final work = p.join(p.dirname(into), '.${p.basename(into)}.unpacking');
    _rmtree(work);
    Directory(work).createSync(recursive: true);
    posix.chmodPath(work, 0x1c0);
    try {
      final ok = await runWithDiskBudget(
        extractArgv(appimage, work),
        work,
        maxAppBytes,
        const Duration(seconds: 600),
      );
      if (!ok || !_isDir(p.join(work, 'squashfs-root'))) {
        throw StateError('could not unpack ${p.basename(appimage)}');
      }
      if (folderBytes(work, maxAppBytes) > maxAppBytes) {
        throw StateError('${p.basename(appimage)} is too large to unpack');
      }
      Directory(p.join(work, 'squashfs-root')).renameSync(into);
    } finally {
      _rmtree(work);
    }
    return into;
  }

  // --- the start command -----------------------------------------------------

  String folderFor(String name) {
    for (final (pattern, folder) in _folders) {
      if (RegExp(pattern, caseSensitive: false).hasMatch(name)) {
        return p.join(home, folder);
      }
    }
    return p.join(home, 'Documents');
  }

  (List<String>, bool) commandFor(String program, String usage) {
    final name = p.basename(program);
    if (name.toLowerCase().contains('mcp') && !usage.contains(' mcp')) {
      return ([program], true);
    }
    if (usage.isEmpty) return ([program, 'mcp'], false);
    final command = [program, 'mcp'];
    if (RegExp(r'\|\s*--headless\b|\[--headless\]').hasMatch(usage)) {
      command.add('--headless');
    }
    final folder = folderFor(name);
    for (final m in RegExp(
      r'--(?:[\w-]*(?:read|write)[\w-]*-)?root\b',
    ).allMatches(usage)) {
      if (!command.contains(m[0])) command.addAll([m[0]!, folder]);
    }
    return (command, true);
  }

  static String serverName(String program) {
    var name = p
        .basename(program)
        .toLowerCase()
        .replaceFirst(RegExp(r'(-cli|-mcp|-mcp-server|-server)$'), '');
    name = name.replaceFirst(RegExp(r'^mcp-server-|^mcp-'), '');
    name = name.replaceAll(RegExp(r'[^a-z0-9_.-]'), '-');
    if (name.length > 64) name = name.substring(0, 64);
    return name.isEmpty ? 'server' : name;
  }

  // --- all together ----------------------------------------------------------

  static bool _counts(String program, int count, String text) {
    final named = p.basename(program).toLowerCase().contains('mcp');
    return text.isNotEmpty && count >= 1 || count >= 2 || named && count >= 1;
  }

  /// scan: MCP servers offered by programs on this PC. configured: real
  /// program path → the agents that have a server starting it; skip: the
  /// clients (mcp_scan.clients and the agents' commands).
  List<Candidate> scan(Map<String, List<String>> configured, Set<String> skip) {
    final seen = <String>{};
    final found = <Candidate>[];

    void consider(String program) {
      final real = resolve(program);
      if (seen.contains(real) ||
          skip.contains(p.basename(program)) ||
          skip.contains(p.basename(real)) ||
          real.contains('/mise/installs/')) {
        return;
      }
      seen.add(real);
      if (!_elfOrScript(real)) return;
      final (count, usage) = scanFile(real);
      if (!_counts(program, count, usage)) return;
      final text = _decode(usage);
      final (command, sure) = commandFor(program, text);
      found.add(
        Candidate(
          serverName(program),
          program,
          command,
          usage: text,
          configured: configured[real] ?? const [],
          sure: sure,
        ),
      );
    }

    final extracted = <String>{};
    for (final program in ownPrograms()) {
      extracted.add(
        p.basename(p.dirname(program)) == 'bin'
            ? p.basename(p.dirname(p.dirname(p.dirname(program))))
            : '',
      );
      consider(program);
    }
    pathPrograms().forEach(consider);
    for (final image in appimages()) {
      if (extracted.contains(appimageStem(image))) continue;
      for (final (name, count, text)
          in lookedInto(image) ?? const <(String, int, String)>[]) {
        final program = p.join(
          home,
          'Applications',
          appimageStem(image),
          'usr/bin',
          name,
        );
        if (!_counts(program, count, text)) continue;
        final (command, sure) = commandFor(program, text);
        found.add(
          Candidate(
            serverName(program),
            program,
            command,
            usage: text,
            appimage: image,
            configured: configured[program] ?? const [],
            sure: sure,
            inner: name,
          ),
        );
      }
    }
    saveCache();
    return foldVersions(found);
  }

  (String, List<int>, String?)? _appOf(Candidate c) {
    if (c.appimage.isNotEmpty) {
      final info = appVersion(appimageStem(c.appimage));
      return info == null ? null : (info.$1, info.$2, null);
    }
    final real = resolve(c.program);
    final apps = p.join(resolve(home), 'Applications');
    if (!p.isWithin(apps, real)) return null;
    final rest = p.split(p.relative(real, from: apps));
    if (rest.length < 2) return null;
    final info = appVersion(rest.first);
    return info == null
        ? null
        : (info.$1, info.$2, p.join(home, 'Applications', rest.first));
  }

  /// fold_versions: one entry per app program, the newest version; it says
  /// which version it updates and who starts the older ones.
  List<Candidate> foldVersions(List<Candidate> found) {
    final groups = <(String, String), List<(List<int>, String?, Candidate)>>{};
    final result = <Candidate>[];
    for (final c in found) {
      final info = _appOf(c);
      if (info == null) {
        result.add(c);
        continue;
      }
      final (app, version, folder) = info;
      c.version = version.join('.');
      final name = c.inner.isNotEmpty
          ? c.inner
          : p.basename(resolve(c.program));
      groups.putIfAbsent((app, name), () => []).add((version, folder, c));
    }
    for (final items in groups.values) {
      _stableSort(items, (a, b) => compareVersions(a.$1, b.$1));
      final newest = items.last.$3;
      final older = [
        for (final item in items.take(items.length - 1))
          if (compareVersions(item.$1, items.last.$1) < 0) item,
      ];
      if (older.isNotEmpty) {
        final used = [
          for (final item in older)
            if (item.$3.configured.isNotEmpty) item,
        ];
        newest.updateFrom = (used.isNotEmpty ? used : older).last.$1.join('.');
        for (final (_, folder, c) in older) {
          for (final path in [c.program, resolve(c.program)]) {
            if (!newest.replaces.contains(path)) newest.replaces.add(path);
          }
          if (folder != null && !newest.oldFolders.contains(folder)) {
            newest.oldFolders.add(folder);
          }
          newest.users.addAll(
            c.configured.where((a) => !newest.users.contains(a)),
          );
        }
      }
      result.add(newest);
    }
    return result;
  }

  static void _stableSort<T>(List<T> items, int Function(T, T) compare) {
    final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
    indexed.sort((a, b) {
      final c = compare(a.$2, b.$2);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    items
      ..clear()
      ..addAll(indexed.map((e) => e.$2));
  }

  // --- skill sets (skills_scan) ---------------------------------------------

  static const _skipFolders = {
    'icons', 'locale', 'man', 'doc', 'fonts', 'themes', 'mime', 'zoneinfo', //
    'help', 'i18n', 'info', 'backgrounds', 'wallpapers', 'sounds', 'pixmaps',
    'applications', 'Trash', 'Steam', 'flatpak', 'containers', 'mise', 'pnpm',
    'uv', 'pipx', 'node_modules_cache', 'baloo', 'akonadi', 'gvfs-metadata',
    'recently-used.xbel', 'keyrings', 'nvim', 'tracker3', 'ai-agents-map',
    'kxmlgui5', 'gnome-shell', 'omarchy-plugin-i18n', '.git', '__pycache__',
    'marketplaces', 'site-packages', 'dist-packages', 'ollama', 'lm-studio',
  };
  static const _maxDirs = 20000, _maxEntries = 2000;

  String tilde(String path) => path == home || p.isWithin(home, path)
      ? '~${path.substring(home.length)}'
      : path;

  List<String> _skillsIn(String folder) {
    try {
      final names = [
        for (final e in _head(folder, _maxEntries))
          if (!p.basename(e.path).startsWith('.') &&
              _isDir(e.path) &&
              _isFile(p.join(e.path, 'SKILL.md')))
            p.basename(e.path),
      ]..sort();
      return names.take(200).toList();
    } on FileSystemException {
      return [];
    }
  }

  static String originOf(String folder) {
    const out = {'/', 'usr', 'share', 'local', 'opt', 'skills', 'lib'};
    final parts = [
      for (final x in p.split(folder))
        if (!out.contains(x)) x,
    ];
    return parts.isNotEmpty ? parts.last : p.basename(folder);
  }

  /// Python's os.path.realpath: links resolved, missing parts kept.
  static String realpath(String path) => resolve(path);

  /// skills_scan.scan: skill sets not among [known] (folders agents read).
  List<SkillSet> skillSets(Iterable<String> known) {
    final knownReal = {for (final k in known) realpath(_expand(k))};
    final found = <SkillSet>[];
    final seen = <String>{};
    var visited = 0;
    final roots = [
      for (final folder in _added(skillFolders)) (folder, 3),
      ...skillRoots,
    ];
    for (final (root, depth) in roots) {
      final stack = [(root, 0)];
      while (stack.isNotEmpty && visited < _maxDirs) {
        final (folder, level) = stack.removeLast();
        visited++;
        List<String> entries;
        try {
          entries = [
            for (final e in _head(folder, _maxEntries))
              if (e is Directory) e.path,
          ];
        } on FileSystemException {
          continue;
        }
        if (entries.any((e) => _isFile(p.join(e, 'SKILL.md')))) {
          final real = realpath(folder);
          if (!knownReal.contains(real) && !seen.contains(real)) {
            seen.add(real);
            found.add((
              path: tilde(folder),
              skills: _skillsIn(folder),
              origin: originOf(folder),
            ));
          }
          continue; // a skill set: its skills are not sets of their own
        }
        if (level >= depth) continue;
        for (final entry in entries) {
          if (visited + stack.length >= _maxDirs) break;
          final name = p.basename(entry);
          if (_skipFolders.contains(name) ||
              name.startsWith('.') && name != '.claude') {
            continue;
          }
          stack.add((entry, level + 1));
        }
      }
    }
    found.sort((a, b) => a.path.compareTo(b.path));
    return found;
  }
}
