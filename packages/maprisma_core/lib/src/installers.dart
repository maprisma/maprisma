import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'process_group.dart' show ProcessGroup;
import 'package:path/path.dart' as p;
import 'context.dart' show bestContext;
import 'desktop.dart' show whichIn;
import 'model_downloads.dart';
import 'model_hub.dart' show boundedOutput, netFetch;
import 'posix_ffi.dart';
import 'provider_facts.dart';
import 'provider_scans.dart' show ProviderScans;
import 'py_values.dart' show pyJsonDumps;
import 'scan_files.dart' show ScanFiles;
import 'tar_check.dart';

/// install_ctl: first installs of local LLMs and tools into a folder of their
/// own, from registered releases whose checksums the release lists. Layout:
/// `<folder>/<version>/…`, `<folder>/current -> <version>`, the marker
/// `.maprisma`, `~/.local/bin/<command>`, a settings file and a user
/// service. Nothing of a release runs while it is installed (Jan's AppImage
/// unpacks itself closed in by bubblewrap).

const marker = '.maprisma';

/// The marker the GTK app (AI Agents Map) wrote: its installs are still
/// recognised and updated, the marker is never written again.
const legacyMarker = '.ai-agents-map';
const maxUnpacked = 20 * 1024 * 1024 * 1024;
final nameRe = RegExp(r'^[A-Za-z0-9._-]{1,128}$');
final _hex = RegExp(r'^([0-9a-f]{64}|[0-9a-f]{128})$');
final _unitSafe = RegExp('^[^\\x00-\\x1f\\x7f%"\'\\\\\$`]+\$');

final class Release {
  Release(
    this.version, [
    List<(String, String, int)>? assets,
    Map<String, String>? digests,
  ]) : assets = assets ?? [],
       digests = digests ?? {};
  final String version;
  final List<(String, String, int)> assets; // name, url, size
  final Map<String, String> digests; // name -> SHA-256 (or SHA-512) hex
  int get size => assets.fold(0, (sum, a) => sum + a.$3);

  Map<String, dynamic> toJson() => {
    'version': version,
    'assets': [
      for (final a in assets) [a.$1, a.$2, a.$3],
    ],
    'digests': {...digests},
  };

  /// Release.from_json: a kept release, checked again before use.
  static Release fromJson(Map data) {
    final version = '${data['version'] ?? ''}';
    if (!nameRe.hasMatch(version)) throw const FormatException('bad release');
    final assets = <(String, String, int)>[];
    for (final item in ((data['assets'] ?? []) as List).take(8)) {
      final list = item as List;
      final name = '${list[0]}', url = '${list[1]}';
      final size = (list[2] as num).toInt();
      if (!nameRe.hasMatch(name) || !url.startsWith('https://') || size < 0) {
        throw const FormatException('bad release');
      }
      assets.add((name, url, size));
    }
    final digests = <String, String>{
      for (final e in ((data['digests'] ?? {}) as Map).entries)
        if (_hex.hasMatch('${e.value}')) '${e.key}': '${e.value}',
    };
    return Release(version, assets, digests);
  }
}

final class Gpu {
  Gpu({
    this.vendor = 'cpu',
    this.name = '',
    this.index,
    this.count = 0,
    this.vram = 0,
  });
  String vendor, name;
  int? index;
  int count, vram;
  Map<String, dynamic> toJson() => {
    'vendor': vendor,
    'name': name,
    'index': index,
    'count': count,
    'vram': vram,
  };
  static Gpu fromJson(Map data) => Gpu(
    vendor: data['vendor'] as String,
    name: data['name'] as String,
    index: data['index'] as int?,
    count: data['count'] as int,
    vram: data['vram'] as int,
  );
}

/// detect_gpu: the card with the most video memory (AMD or NVIDIA).
Future<Gpu> detectGpu() async {
  final cards = <(String, int, String)>[];
  List<String> devices;
  try {
    devices = [
      for (final e in Directory('/sys/class/drm').listSync(followLinks: false))
        if (RegExp(r'^card[0-9]').hasMatch(p.basename(e.path)))
          '${e.path}/device',
    ]..sort();
  } on FileSystemException {
    devices = [];
  }
  for (final device in devices) {
    if (FileSystemEntity.typeSync(device) == FileSystemEntityType.notFound) {
      continue;
    }
    try {
      final vendor = File('$device/vendor').readAsStringSync().trim();
      final total = File('$device/mem_info_vram_total');
      final vram = total.existsSync()
          ? int.parse(total.readAsStringSync().trim())
          : 0;
      final slot = p.basename(Directory(device).resolveSymbolicLinksSync());
      if ((vendor == '0x1002' || vendor == '0x10de') &&
          !cards.any((c) => c.$3 == slot)) {
        cards.add((vendor, vram, slot));
      }
    } on FileSystemException {
      continue;
    } on FormatException {
      continue;
    }
  }
  if (cards.isEmpty) return Gpu();
  cards.sort(
    (a, b) => a.$3.compareTo(b.$3),
  ); // PCI order, as ROCm and CUDA count
  var best = cards.first;
  for (final c in cards) {
    if (c.$2 > best.$2) best = c;
  }
  final same = cards.where((c) => c.$1 == best.$1).toList();
  final gpu = Gpu(
    vendor: best.$1 == '0x1002' ? 'amd' : 'nvidia',
    count: same.length,
    vram: best.$2,
  )..index = same.length > 1 ? same.indexOf(best) : null;
  final (out, _) = await boundedOutput(['lspci'], maxBytes: 256 * 1024);
  final names = [
    for (final line
        in utf8.decode(out, allowMalformed: true).split(RegExp(r'\r\n|[\n\r]')))
      if (RegExp('VGA|Display|3D').hasMatch(line))
        line.contains(': ') ? line.substring(line.indexOf(': ') + 2) : line,
  ];
  final name =
      names
          .where((n) => n.contains('AMD') == (gpu.vendor == 'amd'))
          .firstOrNull ??
      '';
  gpu.name = String.fromCharCodes(name.runes.take(120));
  return gpu;
}

void checkEnvValue(String value) {
  if (!_unitSafe.hasMatch(value.isEmpty ? 'x' : value) || value.length > 1024) {
    throw StateError(
      'this path has characters a service file cannot hold (% " \' \\ \$ `)',
    );
  }
}

/// unit_path: one argument of a service file, checked, in double quotes.
String unitPath(String path) {
  checkEnvValue(path);
  return '"$path"';
}

Future<Map> _json(String url, {int maxBytes = 2000000}) async {
  final data = jsonDecode(
    utf8.decode(await netFetch(url, maxBytes: maxBytes), allowMalformed: true),
  );
  if (data is! Map) throw StateError('unexpected answer');
  return data;
}

Future<dynamic> _jsonAny(String url) async => jsonDecode(
  utf8.decode(await netFetch(url, maxBytes: 5000000), allowMalformed: true),
);

/// github_release: every asset with the SHA-256 GitHub lists for it.
Release githubRelease(String version, List<Map> assets) {
  final picked = <(String, String, int)>[], digests = <String, String>{};
  for (final asset in assets) {
    final name = '${asset['name'] ?? ''}';
    final match = RegExp(
      r'^sha256:([0-9a-f]{64})$',
    ).firstMatch('${asset['digest'] ?? ''}');
    if (match == null) {
      throw StateError('$name: the release lists no SHA-256 checksum');
    }
    final url = asset['browser_download_url'];
    if (url == null) throw StateError('$name: no download address');
    picked.add((name, '$url', ((asset['size'] ?? 0) as num).toInt()));
    digests[name] = match.group(1)!;
  }
  return Release(version, picked, digests);
}

Map<String, Map> _byName(Map data) => {
  for (final a in (data['assets'] ?? []) as List)
    if (a is Map) '${a['name']}': a,
};

bool _lexists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;
bool _isLink(String path) => FileSystemEntity.isLinkSync(path);
bool _exists(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// holds: path is the model folder or contains it (links resolved).
bool holds(String path, String? models) {
  if (models == null) return false;
  final inside = realpathLoose(path), model = realpathLoose(models);
  return inside == model || p.isWithin(inside, model);
}

final _posix = Posix();

/// The files below folder as os.walk lists them (links to folders are not
/// files), their lstat sizes added; stops counting past `most`.
int folderBytes(String folder, [int most = 0]) {
  var total = 0;
  try {
    for (final e in Directory(
      folder,
    ).listSync(recursive: true, followLinks: false)) {
      if (e is Directory ||
          e is Link && FileSystemEntity.isDirectorySync(e.path)) {
        continue;
      }
      total += _posix.lstatOwn(e.path)?.size ?? 0;
      if (most > 0 && total > most) return total;
    }
  } on FileSystemException {
    /* counted what could be read */
  }
  return total;
}

/// check_unpacked_size: an unpacked release over the limit is removed again.
void checkUnpackedSize(String folder, [int limit = maxUnpacked]) {
  if (folderBytes(folder, limit) > limit) {
    _rmtree(folder);
    throw StateError('the unpacked release is too large');
  }
}

void _rmtree(String path) {
  try {
    Directory(path).deleteSync(recursive: true);
  } on FileSystemException {
    /* ignore_errors */
  }
}

/// extract: the archive checked first, then tar without owners or modes.
Future<void> extract(String archive, String folder, {String? name}) async {
  await checkArchive(archive);
  Directory(folder).createSync(recursive: true);
  name ??= p.basename(archive); // an fd path comes with the asset's name
  final flag = name.endsWith('.zst')
      ? '--zstd'
      : name.endsWith('.tgz') || name.endsWith('.gz')
      ? '-z'
      : '';
  try {
    final (out, ok) = await boundedOutput(
      [
        'tar',
        '-x',
        '-f',
        archive,
        '-C',
        folder,
        '--no-same-owner',
        '--no-same-permissions',
        if (flag.isNotEmpty) flag,
      ],
      timeout: const Duration(seconds: 1800),
      mergeStderr: true,
    );
    if (!ok) {
      final text = utf8.decode(out, allowMalformed: true).trim();
      throw StateError(
        'unpacking failed: ${text.length > 300 ? text.substring(0, 300) : text}',
      );
    }
    checkUnpackedSize(folder);
  } catch (_) {
    _rmtree(folder);
    rethrow;
  }
}

/// ai_core.run_with_disk_budget: argv in its own session, its group ended
/// when what it writes in cwd grows past the budget or the time is up.
Future<bool> runWithDiskBudget(
  List<String> argv,
  String cwd,
  int budget,
  Duration timeout,
) async {
  final process = await Process.start('setsid', argv, workingDirectory: cwd);
  final group = ProcessGroup(process.pid)..watch(); // never by number
  process.stdin.close();
  process.stdout.drain<void>();
  process.stderr.drain<void>();
  final deadline = DateTime.now().add(timeout);
  int? code;
  process.exitCode.then((c) => code = c);
  try {
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (code != null) return code == 0 && folderBytes(cwd, budget) <= budget;
      if (DateTime.now().isAfter(deadline) ||
          folderBytes(cwd, budget) > budget) {
        return false;
      }
    }
  } finally {
    // Always the whole group, also after the program itself has ended.
    group.signal(9);
    group.close();
    await process.exitCode;
  }
}

/// install_ctl.private_group: whether [gid] is this account's own group —
/// its primary group, with no other member in /etc/group and no other
/// account having it as primary group in /etc/passwd.
bool privateGroup(int? gid, [Posix? posix]) {
  final px = posix ?? _posix;
  if (gid == null || gid != px.gid) return false;
  String? me;
  try {
    for (final line in File('/etc/passwd').readAsLinesSync()) {
      final f = line.split(':');
      if (f.length < 4) continue;
      if (int.tryParse(f[2]) == px.uid) {
        me = f[0];
      } else if (int.tryParse(f[3]) == gid) {
        return false; // another account's primary group too
      }
    }
    for (final line in File('/etc/group').readAsLinesSync()) {
      final f = line.split(':');
      if (f.length < 4 || int.tryParse(f[2]) != gid) continue;
      final members = f[3].split(',').where((m) => m.isNotEmpty);
      if (members.any((m) => m != me)) return false;
    }
  } on FileSystemException {
    return false;
  }
  return me != null;
}

/// install_ctl.check_trusted: the program folder must be safe from other
/// accounts all the way. The path is resolved here one part at a time, as the
/// kernel would, and every folder and every link met on the way (also links
/// inside a link's target) must belong to this account or root; a folder
/// others may write must have the sticky bit (as /tmp), so they cannot rename
/// or replace what is in it; the program folder itself must be writable only
/// by this account and not be a link. Parts not there yet are created by
/// claim() inside the last checked folder, which checks again afterwards.
void checkTrusted(String path, [Posix? posix]) {
  final px = posix ?? _posix;
  if (!p.isAbsolute(path)) {
    throw StateError('$path: the program folder must be an absolute path');
  }
  if (p.split(path).contains('..')) {
    throw StateError("$path: no '..' in the program folder's path");
  }
  final me = px.uid;
  const typeMask = 0xf000, dirType = 0x4000, linkType = 0xa000;
  void owned(String where, int uid) {
    if (uid != 0 && uid != me) {
      throw StateError('$where belongs to another account; choose a folder of your own');
    }
  }

  void folderOk(String where, int mode, bool leaf) {
    if (mode & typeMask != dirType) {
      throw StateError('$where is not a folder; nothing was installed');
    }
    // Group write counts only when the group is not this account's own
    // private group (a 0770 home with a group of its own is private).
    final groupWrite = mode & 0x10 != 0 && !privateGroup(px.lstatGid(where), px);
    final othersWrite = groupWrite || mode & 0x02 != 0;
    if (othersWrite && (leaf || mode & 0x200 == 0)) {
      throw StateError('other accounts can change $where; choose a folder only you can write');
    }
  }

  var current = '/';
  final root = px.lstatFull('/');
  if (root == null) throw StateError('/ cannot be read');
  owned('/', root.uid);
  folderOk('/', root.mode, false);
  // (name, the last part as written?) — the program folder may not be a link.
  final names = p.split(path).skip(1).toList();
  final parts = [
    for (final (i, name) in names.indexed) (name, i == names.length - 1),
  ];
  var hops = 0;
  while (parts.isNotEmpty) {
    final (name, lastWritten) = parts.removeAt(0);
    if (name.isEmpty || name == '.') continue;
    if (name == '..') {
      current = p.dirname(current); // only from a link's target
      continue;
    }
    final next = p.join(current, name);
    final st = px.lstatFull(next);
    if (st == null) return; // the rest is created in `current` (checked)
    owned(next, st.uid);
    if (st.mode & typeMask == linkType) {
      if (lastWritten) {
        throw StateError('$next is a link; choose the folder itself');
      }
      if (++hops > 40) throw StateError('$path: too many links');
      final target = Link(next).targetSync();
      if (p.isAbsolute(target)) current = '/';
      parts.insertAll(0, [
        for (final part in p.split(target))
          if (part != '/') (part, false),
      ]);
      continue;
    }
    folderOk(next, st.mode, parts.isEmpty);
    current = next;
  }
}

/// install_ctl.open_verified: a downloaded file opened once (no link), this
/// account's own regular file with one name that no other account can write,
/// its bytes checked against `digest` through that descriptor. Close the fd.
int openVerified(ModelFiles files, String path, String digest) {
  final posix = files.posix;
  final int fd;
  try {
    fd = posix.openAt(-100, path, 0x20000); // O_RDONLY | O_NOFOLLOW (+ O_CLOEXEC)
  } on FileSystemException catch (error) {
    throw StateError('${p.basename(path)}: ${error.message}; nothing was installed');
  }
  try {
    final st = posix.statFull(fd);
    if (st.mode & 0xf000 != 0x8000 || st.uid != posix.uid || st.nlink != 1) {
      throw StateError("${p.basename(path)} is not this account's own download; nothing was installed");
    }
    if (st.mode & 0x12 != 0) {
      throw StateError('other accounts can write ${p.basename(path)}; nothing was installed');
    }
    if (files.digestOfFd(fd, digest) != digest) {
      throw StateError("${p.basename(path)} does not match the release's checksum; nothing was installed");
    }
    return fd;
  } catch (_) {
    posix.close(fd);
    rethrow;
  }
}

/// The program an Installer works with: the account's own files.
final class InstallHost {
  InstallHost(this.home, this.posix, {this.path});
  final String home;
  final Posix posix;
  final String? path; // PATH for the tool checks
  String get binDir => '$home/.local/bin';
  String get unitDir => '$home/.config/systemd/user';

  /// _write: a new file beside it, its mode set, then renamed over.
  void write(String path, String text, [int mode = 0x1a4]) {
    if ((path.endsWith('.service') || path.endsWith('.desktop')) &&
        (text.replaceAll(' %U', '').contains('%') ||
            text.codeUnits.any((c) => c < 32 && c != 10))) {
      throw StateError(
        '${p.basename(path)}: a path holds characters a service file cannot have',
      );
    }
    Directory(p.dirname(path)).createSync(recursive: true);
    posix.replaceFile(path, utf8.encode(text), mode);
  }

  Future<(bool, String)> systemctl(List<String> args) async {
    final (out, ok) = await boundedOutput(
      ['systemctl', '--user', ...args],
      timeout: const Duration(seconds: 60),
      mergeStderr: true,
    );
    final text = utf8.decode(out, allowMalformed: true).trim();
    return (ok, text.length > 300 ? text.substring(0, 300) : text);
  }

  Map<String, String> readEnv(String path) {
    final values = <String, String>{};
    String text;
    try {
      final handle = File(path).openSync();
      try {
        text = utf8.decode(handle.readSync(65536), allowMalformed: true);
      } finally {
        handle.closeSync();
      }
    } on FileSystemException {
      return values;
    }
    for (final m in RegExp(
      r'^\s*([A-Z_][A-Z0-9_]*)=(.*)$',
      multiLine: true,
    ).allMatches(text)) {
      values[m.group(1)!] = _stripQuotes(m.group(2)!.trim());
    }
    return values;
  }

  static String _stripQuotes(String value) {
    var start = 0, end = value.length;
    while (start < end && (value[start] == '"' || value[start] == "'")) {
      start++;
    }
    while (end > start && (value[end - 1] == '"' || value[end - 1] == "'")) {
      end--;
    }
    return value.substring(start, end);
  }
}

/// Installer: what all user-folder installs share.
abstract class Installer {
  Installer(this.host);
  final InstallHost host;
  String get key;
  String get name;
  String get command;
  String get service => '';
  String get binRel;
  String get typeName; // the reference's class, part of the reviewed preview
  String? get envFile => null; // null: none (the reference's HOME)
  String get address => '';
  bool get hasService => true;
  bool get usesModels => true;
  bool get canInstall => true;
  List<(String, String)> get builds => const [];

  String get home => host.home;
  String get defaultFolder => '$home/.local/share/maprisma/$key';
  String defaultBuild(Gpu gpu) => builds.isEmpty ? '' : builds.first.$1;
  Future<Release> latest(Gpu gpu, String build);
  /// `name`: the release file's name (its kind) when `archive` is the open,
  /// checked file's `/proc/<pid>/fd` path (openVerified).
  Future<void> unpack(String archive, String folder, {String? name}) =>
      extract(archive, folder, name: name);
  String envText(String? models, Gpu gpu) => '';
  String unitText(String? models) => '';
  Future<void> configure(String? models) async {}

  /// installed_folder: our program folder, from the ~/.local/bin link.
  String? installedFolder() {
    final link = '${host.binDir}/$command';
    if (!_isLink(link)) return null;
    var target = Link(link).targetSync();
    while (true) {
      final parent = p.dirname(target);
      if (parent == target || parent == '.') return null;
      target = parent;
      if (p.basename(target) == 'current') {
        final folder = p.dirname(target);
        return _exists('$folder/$marker') || _exists('$folder/$legacyMarker')
            ? folder
            : null;
      }
    }
  }

  String currentVersion() {
    final folder = installedFolder();
    return folder == null ? '' : currentVersionIn(folder);
  }

  String currentVersionIn(String folder) {
    try {
      return Link('$folder/current').targetSync();
    } on FileSystemException {
      return '';
    }
  }

  Map? readMarker(String folder) =>
      _readMarker('$folder/$marker') ?? _readMarker('$folder/$legacyMarker');

  Map? _readMarker(String path) {
    try {
      if (_isLink(path) ||
          !FileSystemEntity.isFileSync(path) ||
          File(path).lengthSync() > 64 * 1024) {
        return null;
      }
      final data = jsonDecode(File(path).readAsStringSync());
      return data is Map && data['runtime'] == key ? data : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// claim: a new or empty folder (the model folder may be in it), or ours.
  void claim(String folder, String? models) {
    checkTrusted(folder);
    Directory(folder).createSync(recursive: true);
    checkTrusted(folder); // also what was just created
    if (_isLink(folder) || !FileSystemEntity.isDirectorySync(folder)) {
      throw StateError(
        '$folder is not a folder of its own; nothing was installed',
      );
    }
    var mark = readMarker(folder);
    if (mark == null) {
      if (_lexists('$folder/$marker') || _lexists('$folder/$legacyMarker')) {
        throw StateError(
          '$folder belongs to another install; choose an empty folder',
        );
      }
      if (Directory(
        folder,
      ).listSync(followLinks: false).any((c) => !holds(c.path, models))) {
        throw StateError(
          '$folder is not empty; choose an empty folder of its own for $name',
        );
      }
      mark = {'runtime': key, 'versions': []};
    }
    writeMarker(folder, mark);
  }

  void writeMarker(String folder, Map mark) {
    final tmp = File('$folder/$marker.new');
    if (_lexists(tmp.path)) tmp.deleteSync();
    tmp.writeAsStringSync('${pyJsonDumps(mark)}\n');
    tmp.renameSync('$folder/$marker');
  }

  void recordVersion(String folder, String version) {
    final mark = readMarker(folder) ?? {'runtime': key};
    final listed = mark['versions'];
    final known = listed is List ? listed : versions(folder);
    mark['versions'] = [
      ...known.whereType<String>().where((v) => v != version),
      version,
    ];
    writeMarker(folder, mark);
  }

  void checkRoom(String folder, String? models, String version) {
    final downloads = '$folder/downloads';
    if (_isLink(downloads) ||
        (_exists(downloads) && !FileSystemEntity.isDirectorySync(downloads))) {
      throw StateError(
        '$downloads is not a folder of its own; nothing was installed',
      );
    }
    for (final path in [
      downloads,
      '$folder/.$version.partial',
      '$folder/$version',
    ]) {
      if (holds(path, models)) {
        throw StateError(
          'the model folder $models is inside $path, which the install replaces; choose another place for the models',
        );
      }
    }
  }

  void makeRoom(String folder, String path, String? models) {
    if (!_lexists(path)) return;
    if (holds(path, models)) {
      throw StateError(
        '$path holds the model folder; choose another place for the models',
      );
    }
    if (_isLink(path) || !FileSystemEntity.isDirectorySync(path)) {
      throw StateError('$path is in the way; nothing was installed');
    }
    final base = p.basename(path);
    final ours =
        base == 'downloads' ||
        (base.startsWith('.') && base.endsWith('.partial')) ||
        versions(folder).contains(base);
    if (p.dirname(path) != folder || !ours) {
      throw StateError(
        '$path was not put there by Maprisma; nothing was replaced',
      );
    }
    Directory(path).deleteSync(recursive: true);
  }

  List<String> versions(String folder) {
    final mark = readMarker(folder);
    if (mark == null) return [];
    final listed = mark['versions'];
    List<String> names;
    if (listed is List) {
      names = listed.whereType<String>().toList();
    } else {
      final current = currentVersionIn(folder);
      names = [
        for (final e in Directory(folder).listSync(followLinks: false))
          if (p.basename(e.path) == current ||
              (e is Directory && _exists('${e.path}/$binRel')))
            p.basename(e.path),
      ];
    }
    final found = [
      for (final n in names)
        if (nameRe.hasMatch(n) &&
            !n.startsWith('.') &&
            !const {'downloads', 'models', 'current'}.contains(n) &&
            FileSystemEntity.isDirectorySync('$folder/$n') &&
            !_isLink('$folder/$n'))
          n,
    ];
    final times = {
      for (final n in found) n: Directory('$folder/$n').statSync().modified,
    };
    final indexed = [for (var i = 0; i < found.length; i++) (i, found[i])]
      ..sort((a, b) {
        final c = times[a.$2]!.compareTo(times[b.$2]!);
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  Future<void> install(
    String folder,
    String? models,
    bool startAtLogin,
    bool startNow,
    Gpu gpu,
    Release release,
    Progress progress,
  ) async {
    if (!canInstall) {
      throw StateError(
        '$name is not installed from here; use its own installer',
      );
    }
    final missing = [
      for (final a in release.assets)
        if (!release.digests.containsKey(a.$1)) a.$1,
    ];
    if (missing.isNotEmpty) {
      throw StateError(
        '${missing.first}: no SHA-256 checksum to check it against; nothing was installed',
      );
    }
    claim(folder, models);
    checkRoom(folder, models, release.version);
    if (models != null && usesModels) {
      Directory(models).createSync(recursive: true);
    }
    final downloads = '$folder/downloads';
    final files = ModelFiles(host.posix);
    var done = 0;
    for (final (asset, url, size) in release.assets) {
      progress(done / (release.size < 1 ? 1 : release.size), 'download $asset');
      final target = '$downloads/$asset';
      final digest = release.digests[asset]!;
      if (!(files.ownRegularFile(target) &&
          files.digestOf(target, digest) == digest)) {
        await files.download(
          url,
          target,
          size,
          progress,
          doneBefore: done,
          total: release.size,
          sha256: digest,
        );
      }
      done += size;
    }
    progress(1.0, 'unpack');
    final partial = '$folder/.${release.version}.partial';
    makeRoom(folder, partial, models);
    Directory(partial).createSync();
    for (final (asset, _, _) in release.assets) {
      // The checked bytes, not whatever has that name now: opened once, its
      // checksum checked on that descriptor, read through /proc/<pid>/fd.
      final fd = openVerified(files, '$downloads/$asset', release.digests[asset]!);
      try {
        await unpack('/proc/$pid/fd/$fd', partial, name: asset);
      } finally {
        host.posix.close(fd);
      }
    }
    if (!_exists('$partial/$binRel')) flatten(partial);
    if (!_exists('$partial/$binRel')) {
      throw StateError('the download has no $binRel');
    }
    final versionDir = '$folder/${release.version}';
    makeRoom(folder, versionDir, models);
    Directory(partial).renameSync(versionDir);
    makeRoom(folder, downloads, models);
    switchTo(folder, release.version);
    final env = envFile;
    if (env != null) host.write(env, envText(models, gpu), 0x180);
    await configure(models);
    if (hasService) {
      host.write('${host.unitDir}/$service.service', unitText(models));
      await host.systemctl(['daemon-reload']);
      await host.systemctl([
        startAtLogin ? 'enable' : 'disable',
        '$service.service',
      ]);
      if (startNow) {
        final (ok, message) = await host.systemctl([
          'restart',
          '$service.service',
        ]);
        if (!ok) throw StateError('installed, but it did not start: $message');
      }
    }
  }

  /// switch: `current` and the ~/.local/bin link to the version.
  void switchTo(String folder, String version) {
    recordVersion(folder, version);
    final current = '$folder/current';
    final tmp = '$folder/.current.new';
    if (_lexists(tmp)) File(tmp).deleteSync();
    Link(tmp).createSync(version);
    Link(tmp).renameSync(current);
    Directory(host.binDir).createSync(recursive: true);
    final link = '${host.binDir}/$command';
    final owner = installedFolder();
    if (_lexists(link) && owner != null && owner != folder) {
      throw StateError('$link belongs to another install; not replaced');
    }
    if (_exists(link) && !_isLink(link)) {
      throw StateError('$link is a file of its own; not replaced');
    }
    final fresh = '${host.binDir}/.$command.new';
    if (_lexists(fresh)) File(fresh).deleteSync();
    Link(fresh).createSync('$current/$binRel');
    Link(fresh).renameSync(link);
  }
}

/// flatten: an archive with one top folder: its content moves up.
void flatten(String folder) {
  final entries = Directory(folder).listSync(followLinks: false);
  if (entries.length == 1 && entries.first is Directory) {
    final inner = entries.first.path;
    final temp = '$folder/.${p.basename(inner)}.flatten';
    Directory(inner).renameSync(temp);
    for (final child in Directory(temp).listSync(followLinks: false)) {
      child.renameSync('$folder/${p.basename(child.path)}');
    }
    Directory(temp).deleteSync();
  }
}

final class OllamaInstaller extends Installer {
  OllamaInstaller(super.host);
  @override
  String get key => 'ollama';
  @override
  String get name => 'Ollama';
  @override
  String get command => 'ollama';
  @override
  String get service => 'ollama';
  @override
  String get binRel => 'bin/ollama';
  @override
  String get typeName => 'install_ctl.Ollama';
  @override
  String get envFile => '$home/.config/ollama/server.env';
  @override
  String get address => '127.0.0.1:11434';

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    final data = await _json(
      'https://api.github.com/repos/ollama/ollama/releases/latest',
    );
    final version = '${data['tag_name'] ?? ''}';
    if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(version)) {
      throw StateError('no release found');
    }
    final wanted = [
      'ollama-linux-amd64.tar.zst',
      if (gpu.vendor == 'amd') 'ollama-linux-amd64-rocm.tar.zst',
    ];
    final assets = _byName(data);
    if (wanted.any((n) => !assets.containsKey(n))) {
      throw StateError('$version has no Linux build');
    }
    return githubRelease(version, [for (final n in wanted) assets[n]!]);
  }

  @override
  String envText(String? models, Gpu gpu) => [
    '# Written by Maprisma. Change the model folder there (right-click Ollama).',
    'OLLAMA_HOST=$address',
    'OLLAMA_MODELS=${models ?? 'None'}',
    'OLLAMA_MAX_LOADED_MODELS=1',
    if (gpu.vendor == 'amd' && gpu.index != null) ...[
      '# Only the card with the most video memory (not the integrated one).',
      'HIP_VISIBLE_DEVICES=${gpu.index}',
      'ROCR_VISIBLE_DEVICES=${gpu.index}',
    ],
    if (gpu.vendor == 'nvidia' && gpu.index != null)
      'CUDA_VISIBLE_DEVICES=${gpu.index}',
    '',
  ].join('\n');

  @override
  String unitText(String? models) =>
      '''[Unit]
Description=Ollama (installed by Maprisma)
After=network.target

[Service]
Type=exec
EnvironmentFile=$envFile
ExecStart=${unitPath('${host.binDir}/$command')} serve
Restart=on-failure
RestartSec=3
# Stopping also ends the model runners, so no video memory stays taken.
KillMode=control-group

[Install]
WantedBy=default.target
''';
}

final class LlamaCppInstaller extends Installer {
  LlamaCppInstaller(super.host);
  @override
  String get key => 'llamacpp';
  @override
  String get name => 'llama.cpp';
  @override
  String get command => 'llama-server';
  @override
  String get service => 'llama-server';
  @override
  String get binRel => 'llama-server';
  @override
  String get typeName => 'install_ctl.LlamaCpp';
  @override
  String get envFile => '$home/.config/llama.cpp/server.env';
  @override
  String get address => '127.0.0.1:8080';
  @override
  List<(String, String)> get builds => const [
    ('vulkan', 'Vulkan'),
    ('rocm', 'ROCm'),
    ('cuda', 'CUDA'),
    ('cpu', 'CPU'),
  ];
  String get preset => '$home/.config/llama.cpp/models.ini';

  @override
  String defaultBuild(Gpu gpu) {
    if (gpu.vendor == 'nvidia') return 'cuda';
    if (gpu.vendor == 'amd') {
      return File('/opt/rocm/lib/libamdhip64.so').existsSync()
          ? 'rocm'
          : 'vulkan';
    }
    return 'cpu';
  }

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    if (build.isEmpty) build = defaultBuild(gpu);
    final data = await _jsonAny(
      'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=5',
    );
    final pattern = RegExp(
      {
        'vulkan': r'^llama-(b\d+)-bin-ubuntu-vulkan-x64\.tar\.gz$',
        'rocm': r'^llama-(b\d+)-bin-ubuntu-rocm-[\d.]+-x64\.tar\.gz$',
        'cuda': r'^llama-(b\d+)-bin-ubuntu-cuda-12[\d.]*-x64\.tar\.gz$',
        'cpu': r'^llama-(b\d+)-bin-ubuntu-x64\.tar\.gz$',
      }[build]!,
    );
    for (final release in data is List ? data : const []) {
      final assets = [
        for (final a in ((release as Map)['assets'] ?? []) as List)
          if (a is Map) a,
      ];
      final main = assets
          .where((a) => pattern.hasMatch('${a['name']}'))
          .firstOrNull;
      if (main == null) continue;
      final version = pattern.firstMatch('${main['name']}')!.group(1)!;
      final picked = [main];
      if (build == 'cuda') {
        final runtime = RegExp(
          '^cudart-llama-${RegExp.escape(version)}-bin-ubuntu-cuda-12[\\d.]*-x64\\.tar\\.gz\$',
        );
        final found = assets
            .where((a) => runtime.hasMatch('${a['name']}'))
            .firstOrNull;
        if (found != null) picked.add(found);
      }
      return githubRelease('$version-$build', picked);
    }
    throw StateError('no $build build for Linux found');
  }

  @override
  String envText(String? models, Gpu gpu) {
    final at = address.lastIndexOf(':');
    return [
      '# Written by Maprisma. Change the model folder there (right-click llama.cpp).',
      'LLAMA_ARG_MODELS_DIR=${models ?? 'None'}',
      'LLAMA_ARG_HOST=${address.substring(0, at)}',
      'LLAMA_ARG_PORT=${address.substring(at + 1)}',
      'LLAMA_ARG_MODELS_MAX=1',
      if (gpu.vendor == 'amd' && gpu.index != null) ...[
        'HIP_VISIBLE_DEVICES=${gpu.index}',
        'GGML_VK_VISIBLE_DEVICES=${gpu.index}',
      ],
      if (gpu.vendor == 'nvidia' && gpu.index != null)
        'CUDA_VISIBLE_DEVICES=${gpu.index}',
      '',
    ].join('\n');
  }

  @override
  String unitText(String? models) =>
      '''[Unit]
Description=llama.cpp model router (installed by Maprisma)
After=network.target

[Service]
Type=exec
EnvironmentFile=$envFile
# Every GGUF in the model folder; how many are loaded at once is LLAMA_ARG_MODELS_MAX in the
# env file (the app raises it when agents use different models); per-model settings in models.ini.
ExecStart=${unitPath('${host.binDir}/$command')} --models-preset ${unitPath(preset)} --gpu-layers all --flash-attn on
Restart=on-failure
RestartSec=3
KillMode=control-group

[Install]
WantedBy=default.target
''';

  @override
  Future<void> configure(String? models) async {
    if (!_exists(preset)) {
      host.write(
        preset,
        'version = 1\n\n; Settings for every model; a [model name] section overrides them.\n[*]\nctx-size = 8192\n',
      );
    }
  }
}

final class KoboldCppInstaller extends Installer {
  KoboldCppInstaller(super.host);
  @override
  String get key => 'koboldcpp';
  @override
  String get name => 'KoboldCpp';
  @override
  String get command => 'koboldcpp';
  @override
  String get service => 'koboldcpp';
  @override
  String get binRel => 'koboldcpp';
  @override
  String get typeName => 'install_ctl.KoboldCpp';
  @override
  String get envFile => '$home/.config/koboldcpp/server.env';
  @override
  String get address => '127.0.0.1:5001';
  @override
  List<(String, String)> get builds => const [
    ('vulkan', 'Vulkan'),
    ('cuda', 'CUDA'),
    ('cpu', 'CPU'),
  ];
  static const assetNames = {
    'vulkan': 'koboldcpp-linux-x64-nocuda',
    'cuda': 'koboldcpp-linux-x64',
    'cpu': 'koboldcpp-linux-x64-nocuda',
  };
  String get configs => '$home/.config/koboldcpp/models';

  @override
  String defaultBuild(Gpu gpu) => gpu.vendor == 'nvidia'
      ? 'cuda'
      : gpu.vendor == 'amd'
      ? 'vulkan'
      : 'cpu';

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    if (build.isEmpty) build = defaultBuild(gpu);
    final data = await _json(
      'https://api.github.com/repos/LostRuins/koboldcpp/releases/latest',
    );
    final version = '${data['tag_name'] ?? ''}';
    if (!RegExp(r'^v\d+\.\d+(\.\d+)?$').hasMatch(version)) {
      throw StateError('no release found');
    }
    final asset = _byName(data)[assetNames[build]];
    if (asset == null) throw StateError('$version has no Linux build');
    return githubRelease('$version-$build', [asset]);
  }

  /// One program file: copied in as `koboldcpp`, made executable.
  @override
  Future<void> unpack(String archive, String folder, {String? name}) async {
    final target = '$folder/$binRel';
    File(archive).copySync(target);
    host.posix.chmodPath(target, 0x1ed);
  }

  String buildOf() {
    final build = host.readEnv(envFile)['KOBOLDCPP_BUILD'] ?? '';
    return assetNames.containsKey(build) ? build : 'vulkan';
  }

  String modelsFolder() => host.readEnv(envFile)['KOBOLDCPP_MODELS'] ?? '';

  @override
  String envText(String? models, Gpu gpu) {
    var build = defaultBuild(gpu);
    final tail = currentVersion().split('-').last;
    if (assetNames.containsKey(tail)) build = tail;
    return [
      '# Written by Maprisma. Change the model folder there (right-click KoboldCpp).',
      'KOBOLDCPP_MODELS=${models ?? 'None'}',
      'KOBOLDCPP_BUILD=$build',
      if (gpu.vendor == 'nvidia' && gpu.index != null)
        'CUDA_VISIBLE_DEVICES=${gpu.index}',
      '',
    ].join('\n');
  }

  @override
  String unitText(String? models) {
    final at = address.lastIndexOf(':');
    final flag = const {
      'cuda': '--usecuda',
      'vulkan': '--usevulkan',
      'cpu': '--usecpu',
    }[buildOf()];
    return '''[Unit]
Description=KoboldCpp model router (installed by Maprisma)
After=network.target

[Service]
Type=exec
EnvironmentFile=$envFile
# Router mode: every .kcpps in $configs is a model, loaded on request.
ExecStart=${unitPath('${host.binDir}/$command')} --skiplauncher --nomodel --admin --admindir ${unitPath(configs)} --routermode --host ${address.substring(0, at)} --port ${address.substring(at + 1)} $flag --quiet
Restart=on-failure
RestartSec=3
# Stopping ends the model process too, so no video memory stays taken.
KillMode=control-group

[Install]
WantedBy=default.target
''';
  }

  Future<List<String>> sync(String models) async {
    checkEnvValue(models);
    return koboldSync(
      models,
      buildOf(),
      () async => (await detectGpu()).vram,
      configs,
    );
  }

  @override
  Future<void> configure(String? models) async {
    await sync(models!);
  }
}

final _splitRe = RegExp(r'-(\d{5})-of-(\d{5})\.gguf$', caseSensitive: false);

/// kobold_ctl.model_files: GGUFs in the folder and one level below.
List<String> koboldModelFiles(String models) {
  final found = <String>[];
  List<String> sorted(String dir, int limit) => ([
    for (final e in Directory(dir).listSync(followLinks: false)) e.path,
  ]..sort()).take(limit).toList();
  List<String> entries;
  try {
    entries = sorted(models, 1000);
  } on FileSystemException {
    return found;
  }
  for (final entry in entries) {
    var candidates = [entry];
    if (FileSystemEntity.isDirectorySync(entry) &&
        !p.basename(entry).startsWith('.')) {
      try {
        candidates = sorted(entry, 50);
      } on FileSystemException {
        continue;
      }
    }
    for (final path in candidates) {
      final base = p.basename(path).toLowerCase();
      if (!base.endsWith('.gguf') ||
          base.startsWith('mmproj') ||
          base.contains('tokenizer')) {
        continue;
      }
      final split = _splitRe.firstMatch(p.basename(path));
      if (split != null && split.group(1) != '00001') continue;
      found.add(path);
    }
  }
  return found.take(500).toList();
}

String koboldConfigName(String model) {
  var stem = p.basename(model).replaceFirst(_splitRe, '');
  stem = stem.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');
  stem = stem.replaceAll(RegExp(r'[^A-Za-z0-9._+-]'), '_');
  return '${stem.length > 120 ? stem.substring(0, 120) : stem}.kcpps';
}

Map _koboldRead(String path) {
  try {
    if (File(path).lengthSync() > 64 * 1024) return {};
    final data = jsonDecode(File(path).readAsStringSync());
    return data is Map ? data : {};
  } on FileSystemException {
    return {};
  } on FormatException {
    return {};
  }
}

/// kobold_ctl.sync: one .kcpps per model file; ours for vanished files removed.
Future<List<String>> koboldSync(
  String models,
  String build,
  Future<int> Function() vramOf,
  String configs,
) async {
  Directory(configs).createSync(recursive: true);
  final wanted = {
    for (final m in koboldModelFiles(models)) koboldConfigName(m): m,
  };
  final written = <String>[];
  int? vram;
  for (final MapEntry(key: name, value: model) in wanted.entries) {
    final path = '$configs/$name';
    if (_lexists(path)) continue;
    vram ??= await vramOf();
    var best = 0;
    try {
      best = vram > 0 ? bestContext(model, vram, 'f16') : 0;
    } catch (_) {
      best = 0;
    }
    final entry = <String, dynamic>{
      'model_param': model,
      'contextsize': best == 0 ? 8192 : best,
      'gpulayers': -1,
      'flashattention': true,
      'ai_agents_map': true,
      if (build == 'cuda')
        'usecuda': []
      else if (build == 'vulkan')
        'usevulkan': []
      else
        'usecpu': true,
    };
    final tmp = File('$configs/.$name.new')
      ..writeAsStringSync('${pyJsonDumps(entry, indent: 2)}\n');
    Process.runSync('chmod', ['644', tmp.path]);
    tmp.renameSync(path);
    written.add(name);
  }
  for (final e in Directory(configs).listSync(followLinks: false)) {
    if (!e.path.endsWith('.kcpps')) continue;
    final data = _koboldRead(e.path);
    if (data['ai_agents_map'] == true &&
        !wanted.containsKey(p.basename(e.path)) &&
        !_exists('${data['model_param'] ?? ''}')) {
      try {
        File(e.path).deleteSync();
      } on FileSystemException {
        /* missing_ok */
      }
    }
  }
  return written;
}

final class JanInstaller extends Installer {
  JanInstaller(super.host);
  @override
  String get key => 'jan';
  @override
  String get name => 'Jan';
  @override
  String get command => 'jan-desktop';
  @override
  String get service => 'jan';
  @override
  String get binRel => 'squashfs-root/AppRun';
  @override
  String get typeName => 'install_ctl.Jan';
  static const workerRel = 'squashfs-root/usr/lib/Jan/resources/bin';
  String get desktopFile =>
      '$home/.local/share/applications/jan-maprisma.desktop';
  String get janRoot => '$home/.local/share/Jan';

  /// inventory.jan_data_folder.
  String dataFolder() {
    Object? value;
    try {
      final data = jsonDecode(
        File('$janRoot/settings.json').readAsStringSync(),
      );
      value = data is Map ? data['data_folder'] : null;
    } catch (_) {
      value = null;
    }
    if (value is String && value.trim().isNotEmpty) {
      var path = value.trim();
      if (path == '~' || path.startsWith('~/')) {
        path = '$home${path.substring(1)}';
      }
      return p.isAbsolute(path) ? path : '$janRoot/$path';
    }
    return '$janRoot/data';
  }

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    final data = await _json(
      'https://api.github.com/repos/janhq/jan/releases/latest',
    );
    final version = '${data['tag_name'] ?? ''}';
    if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(version)) {
      throw StateError('no release found');
    }
    final asset = _byName(data)['Jan_${version.substring(1)}_amd64.AppImage'];
    if (asset == null) throw StateError('$version has no Linux AppImage');
    return githubRelease(version, [asset]);
  }

  /// unpack_appimage: its own --appimage-extract, closed in by bubblewrap.
  @override
  Future<void> unpack(String archive, String folder, {String? name}) async {
    host.posix.chmodPath(archive, 0x1ed);
    try {
      final bwrap = whichIn('bwrap', host.path);
      if (bwrap == null) {
        throw StateError(
          'unpacking an AppImage needs bubblewrap (bwrap), which keeps it from touching anything else; install bubblewrap',
        );
      }
      final argv = [
        bwrap,
        '--unshare-all',
        '--die-with-parent',
        '--new-session',
        '--clearenv',
        '--ro-bind',
        '/usr',
        '/usr',
        '--symlink',
        'usr/lib',
        '/lib',
        '--symlink',
        'usr/lib64',
        '/lib64',
        '--symlink',
        'usr/bin',
        '/bin',
        '--proc',
        '/proc',
        '--dev',
        '/dev',
        '--tmpfs',
        '/tmp',
        '--ro-bind',
        archive,
        '/in/app.AppImage',
        '--bind',
        folder,
        '/out',
        '--chdir',
        '/out',
        '--',
        '/in/app.AppImage',
        '--appimage-extract',
      ];
      if (!await runWithDiskBudget(
        argv,
        folder,
        maxUnpacked,
        const Duration(seconds: 900),
      )) {
        throw StateError('unpacking the AppImage failed');
      }
      checkUnpackedSize(folder);
    } catch (_) {
      _rmtree(folder);
      rethrow;
    }
  }

  /// set_models_folder_value: Jan's data folder, only before Jan has one.
  void setModelsFolder(String models) {
    final settings = '$janRoot/settings.json';
    Object? data;
    if (!_lexists(settings)) {
      data = {};
    } else {
      try {
        if (File(settings).lengthSync() > 2000000) {
          throw const FormatException('too large');
        }
        data = jsonDecode(utf8.decode(File(settings).readAsBytesSync()));
      } catch (_) {
        throw StateError(
          "Jan's settings.json cannot be read; change the folder in Jan",
        );
      }
    }
    final values = data is Map ? data : <String, dynamic>{};
    final current = dataFolder();
    final chosen = values['data_folder'];
    if (chosen != null && chosen != '' && chosen != false) {
      var path = '$chosen';
      if (path == '~' || path.startsWith('~/')) {
        path = '$home${path.substring(1)}';
      }
      final models0 = '$current/llamacpp/models';
      final hasModels =
          FileSystemEntity.isDirectorySync(models0) &&
          Directory(models0).listSync().isNotEmpty;
      if (p.normalize(path) != p.normalize(models) && hasModels) {
        throw StateError(
          'Jan has models in its data folder already; move it in Jan (Settings › General)',
        );
      }
    }
    values['data_folder'] = models;
    host.write(settings, '${pyJsonDumps(values, indent: 2)}\n');
  }

  @override
  String unitText(String? models) {
    final bin = '${installedFolder() ?? defaultFolder}/current/$workerRel';
    final preset = '${dataFolder()}/llamacpp/router.preset.ini';
    return '''[Unit]
Description=Jan's engine for agents (installed by Maprisma)
After=network.target

[Service]
Type=exec
Environment=${unitPath('LD_LIBRARY_PATH=$bin')}
# jan-llama-worker ends when its input closes (the Jan app's way to stop it):
# `sleep infinity` keeps it open; systemd stops both. The paths reach the shell
# as arguments (\$0, \$1), never as part of its script.
ExecStart=/bin/sh -c 'sleep infinity | exec "\$0" --preset "\$1" --port 6767 --models-max 1' ${unitPath('$bin/jan-llama-worker')} ${unitPath(preset)}
Restart=on-failure
RestartSec=3
KillMode=control-group

[Install]
WantedBy=default.target
''';
  }

  @override
  Future<void> configure(String? models) async {
    setModelsFolder(models!);
    final preset = File('${dataFolder()}/llamacpp/router.preset.ini');
    if (!preset.existsSync()) {
      preset.parent.createSync(recursive: true);
      preset.writeAsStringSync('[*]\nload-on-startup = false\n');
    }
    final folder = installedFolder() ?? defaultFolder;
    final squash = '$folder/current/squashfs-root';
    final icons = FileSystemEntity.isDirectorySync(squash)
        ? ([
            for (final e in Directory(squash).listSync(followLinks: false))
              if (e.path.endsWith('.png')) e.path,
          ]..sort())
        : <String>[];
    host.write(desktopFile, '''[Desktop Entry]
Type=Application
Name=Jan
Comment=Chat with local LLMs (installed by Maprisma)
Exec=${host.binDir}/$command %U
Icon=${icons.firstOrNull ?? 'jan'}
Categories=Development;
Terminal=false
''');
  }
}

/// install_ctl.Strata: Strata's terminal by its own install.sh of one GitHub
/// release (its SHA-256 checked), run with sh; the terminal folder is then
/// marked as the app's install. Strata's engines, run configs and models stay.
final class StrataInstaller extends Installer {
  StrataInstaller(super.host);
  @override
  String get key => 'strata';
  @override
  String get name => 'Strata';
  @override
  String get command => 'strata';
  @override
  String get binRel => 'bin/strata';
  @override
  String get typeName => 'install_ctl.Strata';
  @override
  bool get hasService => false;
  @override
  bool get usesModels => false;

  static const releases =
      'https://api.github.com/repos/Niko1221/Strata/releases/latest';
  static const downloads =
      'https://github.com/Niko1221/Strata/releases/download/';
  static final tagRe = RegExp(r'^v\d{1,4}(?:\.\d{1,6}){1,3}$');
  static const timeout = Duration(seconds: 1800);

  @override
  String get defaultFolder {
    final value = Platform.environment['XDG_DATA_HOME'] ?? '';
    final data = value.startsWith('/') ? value : '$home/.local/share';
    return '$data/strata/terminal';
  }

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    final data = await _json(releases);
    final version = '${data['tag_name'] ?? ''}';
    if (!tagRe.hasMatch(version)) throw StateError('no release found');
    final assets = [
      for (final a in (data['assets'] is List ? data['assets'] as List : []))
        if (a is Map && a['name'] == 'install.sh') a,
    ];
    if (assets.length != 1) throw StateError('$version has no install.sh');
    final release = githubRelease(version, assets);
    if (release.assets.first.$2 != '$downloads$version/install.sh') {
      throw StateError("the installer is not in Strata's release");
    }
    return release;
  }

  /// Its `current` link is absolute (install.sh: `ln -sfn <folder>/<version>`).
  @override
  String currentVersionIn(String folder) {
    try {
      final target = Link('$folder/current').targetSync();
      final parent = p.dirname(target);
      String? real;
      try {
        real = Directory(folder).resolveSymbolicLinksSync();
      } on FileSystemException {
        real = null;
      }
      return parent == folder || parent == '.' || parent == real
          ? p.basename(target)
          : '';
    } on FileSystemException {
      return '';
    }
  }

  /// The marker's versions and the ones Strata's own update put beside them.
  @override
  List<String> versions(String folder) {
    if (readMarker(folder) == null) return [];
    final listed = super.versions(folder);
    final own = <String>[];
    try {
      for (final e in Directory(folder).listSync(followLinks: false)) {
        final n = p.basename(e.path);
        if (nameRe.hasMatch(n) &&
            !n.startsWith('.') &&
            n != 'current' &&
            e is Directory &&
            FileSystemEntity.isFileSync('${e.path}/$binRel') &&
            FileSystemEntity.isFileSync('${e.path}/VERSION')) {
          own.add(n);
        }
      }
    } on FileSystemException {
      /* none */
    }
    final names = [
      ...listed,
      for (final n in own)
        if (!listed.contains(n)) n,
    ];
    final indexed = [for (var i = 0; i < names.length; i++) (i, names[i])]
      ..sort((a, b) {
        final c = Directory('$folder/${a.$2}').statSync().modified.compareTo(
          Directory('$folder/${b.$2}').statSync().modified,
        );
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    return [for (final e in indexed) e.$2];
  }

  @override
  Future<void> install(
    String folder,
    String? models,
    bool startAtLogin,
    bool startNow,
    Gpu gpu,
    Release release,
    Progress progress,
  ) async {
    if (folder != defaultFolder) {
      throw StateError(
        'Strata installs into its own folder ($defaultFolder); nothing was installed',
      );
    }
    if (release.assets.length != 1 ||
        release.assets.first.$1 != 'install.sh' ||
        !release.digests.containsKey('install.sh') ||
        !tagRe.hasMatch(release.version)) {
      throw StateError(
        'install.sh: no SHA-256 checksum to check it against; nothing was installed',
      );
    }
    final link = '${host.binDir}/$command';
    if (_lexists(link) && installedFolder() != folder) {
      throw StateError(
        '$link belongs to another program or install; nothing was installed',
      );
    }
    if (_isLink(folder) ||
        (_lexists(folder) && !FileSystemEntity.isDirectorySync(folder))) {
      throw StateError(
        '$folder is not a folder of its own; nothing was installed',
      );
    }
    if (FileSystemEntity.isDirectorySync(folder) &&
        Directory(folder).listSync(followLinks: false).isNotEmpty &&
        readMarker(folder) == null) {
      throw StateError(
        'Strata is installed already in $folder; update it with `~/.local/bin/strata update`',
      );
    }
    checkTrusted(folder);
    final (asset, url, size) = release.assets.first;
    final work = Directory.systemTemp.createTempSync('maprisma-strata-');
    List<int> out;
    bool ok;
    try {
      final script = '${work.path}/$asset';
      progress(0.0, 'download $asset');
      await ModelFiles(host.posix).download(
        url,
        script,
        size,
        progress,
        doneBefore: 0,
        total: size < 1 ? 1 : size,
        sha256: release.digests[asset]!,
      );
      progress(0.2, 'install.sh');
      // Only this release's feed, and none of the user's STRATA_* settings.
      final env = <String, String>{
        for (final e in Platform.environment.entries)
          if (!e.key.startsWith('STRATA_')) e.key: e.value,
        'STRATA_FEED': '$downloads${release.version}',
      };
      // The checked bytes run: install.sh opened once, its checksum checked
      // on that descriptor, run through /proc/<pid>/fd.
      final files = ModelFiles(host.posix);
      final fd = openVerified(files, script, release.digests[asset]!);
      try {
        (out, ok) = await boundedOutput(
          ['sh', '/proc/$pid/fd/$fd'],
          maxBytes: 256 * 1024,
          timeout: timeout,
          mergeStderr: true,
          environment: env,
          inheritEnvironment: false,
        );
      } finally {
        host.posix.close(fd);
      }
    } finally {
      work.deleteSync(recursive: true);
    }
    if (!ok) {
      final text = utf8.decode(out, allowMalformed: true).trim();
      throw StateError(
        text.isEmpty
            ? 'install.sh failed'
            : text.substring(text.length > 300 ? text.length - 300 : 0),
      );
    }
    final version = currentVersionIn(folder);
    var ours = false;
    try {
      ours =
          _isLink(link) &&
          p.isWithin(
            Directory(folder).resolveSymbolicLinksSync(),
            File(link).resolveSymbolicLinksSync(),
          );
    } on FileSystemException {
      ours = false;
    }
    if (version.isEmpty || !ours) {
      throw StateError(
        'install.sh finished, but its terminal or the strata link is missing',
      );
    }
    recordVersion(folder, version);
    progress(1.0, 'done');
  }
}

final class MiseInstaller extends Installer {
  MiseInstaller(super.host);
  @override
  String get key => 'mise';
  @override
  String get name => 'mise';
  @override
  String get command => 'mise';
  @override
  String get binRel => 'bin/mise';
  @override
  String get typeName => 'install_ctl.Mise';
  @override
  bool get hasService => false;
  @override
  bool get usesModels => false;

  @override
  Future<Release> latest(Gpu gpu, String build) async {
    final arch = switch (Abi.current()) {
      Abi.linuxX64 => 'x64',
      Abi.linuxArm64 => 'arm64',
      _ => throw StateError('no mise build for this machine'),
    };
    final data = await _json(
      'https://api.github.com/repos/jdx/mise/releases/latest',
    );
    final version = '${data['tag_name'] ?? ''}';
    if (!RegExp(r'^v\d{4}\.\d{1,2}\.\d{1,3}$').hasMatch(version)) {
      throw StateError('no mise release found');
    }
    final wanted = 'mise-$version-linux-$arch-musl.tar.gz';
    final assets = [
      for (final a in (data['assets'] ?? []) as List)
        if (a is Map && a['name'] == wanted) a,
    ];
    if (assets.isEmpty) throw StateError('mise $version has no $wanted');
    return githubRelease(version, assets);
  }
}

/// The reference's installers that never install from here: no checksummed
/// release (LM Studio, Bionic: none published; vLLM, dsh: pip/npm; agy: no
/// size), so a preview of them is always refused.
final class RefusedInstaller extends Installer {
  RefusedInstaller(
    super.host,
    this.key,
    this.name,
    this.command, {
    this.installable = true,
  });
  @override
  final String key, name, command;
  final bool installable;
  @override
  String get binRel => '';
  @override
  String get typeName => '';
  @override
  bool get canInstall => installable;
  @override
  bool get hasService => false;
  @override
  Future<Release> latest(Gpu gpu, String build) async =>
      throw StateError('No complete checksummed release');
}

const maxPlan = 128 * 1024;

/// flutter_installers: the registered installers, previews and installs.
final class Installers {
  Installers(this.files, {String? settingsPath})
    : settingsPath = settingsPath ?? '';
  final ScanFiles files;
  final String settingsPath;
  late final host = InstallHost(
    files.identity.home,
    files.posix,
    path: files.identity.environment['PATH'],
  );

  /// INSTALLERS / AGENT_INSTALLERS / TOOL_INSTALLERS for the visible providers.
  Installer? find(String kind, String key) {
    if (kind == 'runtime') {
      final visible = {
        for (final f in visibleProviderFacts['local'] as List)
          (f as Map)['key'],
      };
      if (!visible.contains(key)) return null;
      return switch (key) {
        'ollama' => OllamaInstaller(host),
        'llamacpp' => LlamaCppInstaller(host),
        'koboldcpp' => KoboldCppInstaller(host),
        'jan' => JanInstaller(host),
        'strata' => StrataInstaller(host),
        'vllm' => RefusedInstaller(host, 'vllm', 'vLLM', 'vllm'),
        'lmstudio' => RefusedInstaller(
          host,
          'lmstudio',
          'LM Studio',
          'lm-studio',
          installable: false,
        ),
        _ => null,
      };
    }
    if (kind == 'tool') return key == 'mise' ? MiseInstaller(host) : null;
    return null; // agents: see installer()
  }

  bool _hasTool(String name) {
    if (whichIn(name, host.path) != null) return true;
    try {
      final st = File('${host.binDir}/$name').statSync();
      return st.type == FileSystemEntityType.file && st.mode & 0x40 != 0;
    } on FileSystemException {
      return false;
    }
  }

  /// installer(selection): a missing program this app can install.
  Installer installer(Map selection) {
    if (selection.keys.any(
          (k) => !const {'kind', 'key', 'build'}.contains(k),
        ) ||
        !selection.containsKey('kind') ||
        !selection.containsKey('key') ||
        selection.values.any((v) => v is! String)) {
      throw const FormatException('Invalid installer selection');
    }
    final kind = selection['kind'] as String, key = selection['key'] as String;
    // Agents the reference installs itself (agy, dsh, bionic) never have a
    // complete checksummed release; adapters cannot declare a download.
    final inst = nameRe.hasMatch(key) ? find(kind, key) : null;
    if (inst == null) {
      throw const FormatException('Unknown registered installer');
    }
    if (!inst.canInstall || inst.installedFolder() != null) {
      throw const FormatException(
        'This action requires a missing, installable program',
      );
    }
    if (kind == 'runtime') {
      final rt = ProviderScans(
        files,
      ).scan().where((r) => r.key == key).firstOrNull;
      if (rt == null) throw const FormatException('Unavailable provider');
      if (rt.installed) {
        throw const FormatException(
          'Provider is already installed by another method',
        );
      }
    } else if (_hasTool(inst.command)) {
      throw const FormatException('Prerequisite is already installed');
    }
    if (_lexists('${host.binDir}/${inst.command}')) {
      throw const FormatException(
        'Existing program link or file must not be replaced',
      );
    }
    final protected = [
      if (inst.envFile != null) inst.envFile!,
      if (inst.hasService) '${host.unitDir}/${inst.service}.service',
    ];
    if (protected.any(_lexists)) {
      throw const FormatException(
        'Existing configuration must not be replaced by a first install',
      );
    }
    return inst;
  }

  /// prepare: the release to install, checked, as the preview's record.
  Future<Map<String, dynamic>> prepare(Map selection) async {
    final inst = installer(selection);
    final gpu = inst.usesModels ? await detectGpu() : Gpu();
    final build = (selection['build'] ?? inst.defaultBuild(gpu)) as String;
    if (!{
      ...inst.builds.map((b) => b.$1),
      inst.defaultBuild(gpu),
    }.contains(build)) {
      throw const FormatException('Unavailable hardware build');
    }
    final release = await inst.latest(gpu, build);
    final checked = Release.fromJson(release.toJson());
    if (checked.assets.isEmpty ||
        jsonEncode(checked.toJson()) != jsonEncode(release.toJson()) ||
        checked.assets.any(
          (a) => a.$3 <= 0 || !checked.digests.containsKey(a.$1),
        )) {
      throw const FormatException('No complete checksummed release');
    }
    final folder = inst.defaultFolder;
    final record = <String, dynamic>{
      'version': 1,
      'settings_path': settingsPath.isEmpty ? null : settingsPath,
      'selection': {...selection, 'build': build},
      'name': inst.name,
      'builds': [
        for (final (key, label) in inst.builds) [key, label],
      ],
      'release': checked.toJson(),
      'gpu': gpu.toJson(),
      'folder': folder,
      'models': inst.usesModels ? '$folder/models' : null,
      'source': {
        'type': inst.typeName,
        'key': inst.key,
        'command': inst.command,
        'binary': inst.binRel,
        'service': inst.service,
        'has_service': inst.hasService,
        'uses_models': inst.usesModels,
        'spec': null,
      },
    };
    final body = pyJsonDumps(record);
    if (utf8.encode(body).length > maxPlan) {
      throw const FormatException('Installer preview too large');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  /// execute: the reviewed record, prepared again and the same, installed.
  Future<Map<String, dynamic>> execute(
    List<int> body,
    Progress progress,
  ) async {
    if (body.length > maxPlan) {
      throw const FormatException('Installer plan too large');
    }
    final plan = jsonDecode(utf8.decode(body));
    if (plan is! Map ||
        plan.length != 3 ||
        !const {
          'record',
          'start_now',
          'start_at_login',
        }.every(plan.containsKey) ||
        plan['start_now'] is! bool ||
        plan['start_at_login'] is! bool) {
      throw const FormatException('Invalid private installer plan');
    }
    final record = plan['record'] as Map;
    final current = await prepare(record['selection'] as Map);
    if (jsonEncode(current) != jsonEncode(record)) {
      throw const FormatException(
        'Release, hardware or installer changed; preview again',
      );
    }
    final inst = installer(record['selection'] as Map);
    if (!inst.hasService &&
        (plan['start_now'] == true || plan['start_at_login'] == true)) {
      throw const FormatException('No managed service');
    }
    await inst.install(
      record['folder'] as String,
      record['models'] as String?,
      plan['start_at_login'] as bool,
      plan['start_now'] as bool,
      Gpu.fromJson(record['gpu'] as Map),
      Release.fromJson(record['release'] as Map),
      progress,
    );
    return {
      'ok': true,
      'kind': (record['selection'] as Map)['kind'],
      'key': (record['selection'] as Map)['key'],
      'version': (record['release'] as Map)['version'],
    };
  }
}

/// flutter_installers.Plans: reviewed previews, used once within ten minutes.
final class InstallerPlans {
  InstallerPlans(this.newToken);
  final String Function() newToken;
  final items = <String, (DateTime, Map<String, dynamic>)>{};

  Map<String, dynamic> register(Map<String, dynamic> record) {
    if (record['version'] != 1 ||
        utf8.encode(jsonEncode(record)).length > maxPlan) {
      throw const FormatException('Invalid installer preview');
    }
    final now = DateTime.now();
    items.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (items.length >= 16) {
      items.remove(items.keys.first);
    }
    final token = newToken();
    items[token] = (now, record);
    final release = Release.fromJson(record['release'] as Map);
    final selection = record['selection'] as Map,
        source = record['source'] as Map;
    return {
      'installer': token,
      'kind': selection['kind'],
      'key': selection['key'],
      'name': record['name'],
      'version': release.version,
      'size': release.size,
      'files': [
        for (final a in release.assets) {'name': a.$1, 'size': a.$3},
      ],
      'folder': record['folder'],
      'models': record['models'],
      'gpu': record['gpu'],
      'build': selection['build'],
      'builds': record['builds'],
      'has_service': source['has_service'],
    };
  }

  Map<String, dynamic> apply(
    Map<String, dynamic> params,
    Map<String, dynamic> Function(Map<String, dynamic> plan) queue,
  ) {
    if (params.length != 3 ||
        !const {
          'installer',
          'start_now',
          'start_at_login',
        }.every(params.containsKey) ||
        params['installer'] is! String ||
        params['start_now'] is! bool ||
        params['start_at_login'] is! bool) {
      throw const FormatException('Invalid installer confirmation');
    }
    final kept = items[params['installer']];
    if (kept == null || DateTime.now().difference(kept.$1).inSeconds >= 600) {
      throw const FormatException('Unknown or expired installer preview');
    }
    final record = kept.$2;
    if ((record['source'] as Map)['has_service'] != true &&
        (params['start_now'] == true || params['start_at_login'] == true)) {
      throw const FormatException('This program has no managed service');
    }
    final result = queue({
      'record': record,
      'start_now': params['start_now'],
      'start_at_login': params['start_at_login'],
    });
    items.remove(params['installer']);
    return result;
  }
}
