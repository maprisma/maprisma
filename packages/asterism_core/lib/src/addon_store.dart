import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'addons.dart';
import 'model_hub.dart' show netFetch, FetchError;
import 'posix_ffi.dart';
import 'py_values.dart';
import 'sshsig.dart';

/// addon_store: the signed catalog, installing and updating add-ons from it,
/// and their reviewed removal (flutter_addon_catalog, flutter_addon_actions).
const _repo = 'https://github.com/uBruckhaus/asterism-addons';
const catalogUrl =
    'https://raw.githubusercontent.com/uBruckhaus/asterism-addons/main/catalog.json';
const catalogSignatureUrl =
    'https://raw.githubusercontent.com/uBruckhaus/asterism-addons/main/catalog.sig';
const _downloads = '$_repo/releases/download/';
const checkEvery = 6 * 3600;
const maxCatalog = 1024 * 1024, maxZip = 8 * 1024 * 1024, maxEntries = 200;
const catalogKinds = {'feature', 'agent', 'provider'};
final _id = RegExp(r'^[a-z][a-z0-9-]{1,40}$');
final _version = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
final _sha = RegExp(r'^[0-9a-f]{64}$');
final _iconName = RegExp(r'^[a-z0-9-]{1,64}$');
final _needs = RegExp(r'^(?:asterism\s*>=\s*)?(\d{1,4}\.\d{1,4}\.\d{1,4})$');
final _command = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$');
final _homepage = RegExp(
  r'^https://[A-Za-z0-9.-]{1,100}(/[A-Za-z0-9._~%/+@-]*)?$',
);

String _text(dynamic value, int limit) => value is String
    ? String.fromCharCodes(
        value
            .split(RegExp(r'\s+'))
            .where((w) => w.isNotEmpty)
            .join(' ')
            .runes
            .take(limit),
      )
    : '';

List<String> _texts(dynamic value) => value is! List
    ? []
    : [
        for (final v in value.take(12))
          if (v is String && v.trim().isNotEmpty) _text(v, 300),
      ];

List<int> versionTuple(String v) {
  try {
    return [for (final x in v.split('.')) int.parse(x)];
  } on FormatException {
    return [];
  }
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}

/// addon_store.newer: version a is newer than b.
bool newerVersion(String a, String b) {
  final ta = versionTuple(a), tb = versionTuple(b);
  return ta.isNotEmpty && tb.isNotEmpty && _compare(ta, tb) > 0;
}

/// entry_from: a checked catalog entry (asdict(Entry) field order), or null.
Map<String, dynamic>? entryFrom(dynamic data) {
  if (data is! Map) return null;
  final aid = data['id'], version = data['version'];
  if (aid is! String ||
      !_id.hasMatch(aid) ||
      version is! String ||
      !_version.hasMatch(version) ||
      data['api'] != apiVersion) {
    return null;
  }
  final url = data['url'], sha = data['sha256'], size = data['size'];
  if (url != '$_downloads$aid-$version/$aid-$version.zip' ||
      sha is! String ||
      !_sha.hasMatch(sha) ||
      size is! int ||
      size <= 0 ||
      size > maxZip) {
    return null;
  }
  final caps = data['capabilities'] ?? [];
  if (caps is! List || !caps.every(addonCapabilities.contains)) return null;
  final needs = data['needs'] ?? '';
  final m = needs is String ? _needs.firstMatch(needs.trim()) : null;
  if (needs != '' && needs != null && m == null) return null;
  final detect = data['detect'] is Map ? data['detect'] as Map : const {};
  final commands = detect['commands'], paths = detect['paths'];
  final icon = data['icon'];
  final home = data['homepage'];
  return {
    'id': aid,
    'name': _text(data['name'], 80).isEmpty ? aid : _text(data['name'], 80),
    'version': version,
    'kind': catalogKinds.contains(data['kind']) ? data['kind'] : 'feature',
    'icon': icon is String && _iconName.hasMatch(icon) ? icon : '',
    'summary': _text(data['summary'], 200),
    'description': _text(data['description'], 2000),
    'privacy': privacyLevels[data['privacy']] ?? privacyLevels['numbers'],
    'capabilities': ({for (final c in caps) c as String}.toList()..sort()),
    'harnesses': _texts(data['harnesses']),
    'reads': _texts(data['reads']),
    'sends': _texts(data['sends']),
    'commands': commands is List
        ? [
            for (final c in commands.take(8))
              if (c is String && _command.hasMatch(c)) c,
          ]
        : <String>[],
    'paths': paths is List
        ? [
            for (final x in paths.take(8))
              if (x is String &&
                  x.startsWith('~/') &&
                  !x.contains('..') &&
                  x.length <= 200 &&
                  !x.codeUnits.any((c) => c < 32))
                x,
          ]
        : <String>[],
    'homepage': home is String && home.length <= 300 && _homepage.hasMatch(home)
        ? home
        : '',
    'url': url,
    'size': size,
    'sha256': sha,
    'needs': m?[1] ?? '',
  };
}

/// parse_catalog: per add-on the newest version this Asterism can load, in
/// the order the add-ons first appear; null when the signature fails.
List<Map<String, dynamic>>? parseCatalog(List<int> text, List<int> signature) {
  if (text.length > maxCatalog ||
      !sshSignatureOk(text, signature, signingNamespace, signingKey)) {
    return null;
  }
  dynamic data;
  try {
    data = jsonDecode(utf8.decode(text));
  } catch (_) {
    return null;
  }
  if (data is! Map || data['catalog'] != 1 || data['addons'] is! List) {
    return null;
  }
  final found = <String, Map<String, dynamic>>{};
  final self = versionTuple(asterismVersion);
  for (final raw in (data['addons'] as List).take(maxEntries)) {
    final entry = entryFrom(raw);
    if (entry == null ||
        (entry['needs'] as String).isNotEmpty &&
            _compare(versionTuple(entry['needs']), self) > 0) {
      continue;
    }
    final known = found[entry['id']];
    if (known == null ||
        _compare(
              versionTuple(entry['version']),
              versionTuple(known['version']),
            ) >
            0) {
      found[entry['id']] = entry;
    }
  }
  return found.values.toList();
}

final class InstallError implements Exception {
  InstallError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A zip's entries (name, method, sizes, data offset, mode), from its central
/// directory; then each entry's bytes (stored or deflated).
final class _ZipEntry {
  _ZipEntry(
    this.name,
    this.method,
    this.compressed,
    this.size,
    this.header,
    this.mode,
  );
  final String name;
  final int method, compressed, size, header, mode;
  bool get isDir => name.endsWith('/');
}

List<_ZipEntry> _zipEntries(Uint8List data) {
  final view = ByteData.sublistView(data);
  var end = -1;
  for (
    var i = data.length - 22;
    i >= math.max(0, data.length - 22 - 65535);
    i--
  ) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      end = i;
      break;
    }
  }
  if (end < 0) throw InstallError('not a zip file');
  final count = view.getUint16(end + 10, Endian.little);
  var at = view.getUint32(end + 16, Endian.little);
  final entries = <_ZipEntry>[];
  for (var n = 0; n < count; n++) {
    if (at + 46 > data.length ||
        view.getUint32(at, Endian.little) != 0x02014b50) {
      throw InstallError('not a zip file');
    }
    final method = view.getUint16(at + 10, Endian.little);
    final compressed = view.getUint32(at + 20, Endian.little);
    final size = view.getUint32(at + 24, Endian.little);
    final nameLength = view.getUint16(at + 28, Endian.little);
    final extra = view.getUint16(at + 30, Endian.little);
    final comment = view.getUint16(at + 32, Endian.little);
    final external = view.getUint32(at + 38, Endian.little);
    final header = view.getUint32(at + 42, Endian.little);
    final name = utf8.decode(
      data.sublist(at + 46, at + 46 + nameLength),
      allowMalformed: true,
    );
    entries.add(
      _ZipEntry(name, method, compressed, size, header, external >> 16),
    );
    at += 46 + nameLength + extra + comment;
  }
  return entries;
}

List<int> _zipRead(Uint8List data, _ZipEntry entry) {
  final view = ByteData.sublistView(data);
  final at = entry.header;
  if (at + 30 > data.length ||
      view.getUint32(at, Endian.little) != 0x04034b50) {
    throw InstallError('not a zip file');
  }
  final start =
      at +
      30 +
      view.getUint16(at + 26, Endian.little) +
      view.getUint16(at + 28, Endian.little);
  if (start + entry.compressed > data.length) {
    throw InstallError('not a zip file');
  }
  final raw = data.sublist(start, start + entry.compressed);
  if (entry.method == 0) return raw;
  if (entry.method == 8) return ZLibDecoder(raw: true).convert(raw);
  throw InstallError('not a zip file');
}

final class AddonStore {
  AddonStore(this.posix, this.userDir, this.home, this.verifier);
  final Posix posix;
  final String userDir, home;
  final AddonVerifier verifier;
  String get cache => p.join(home, '.cache/asterism/catalog.json');

  Map? _loadCache() {
    try {
      final data = jsonDecode(
        utf8.decode(posix.readRegular(cache, maxCatalog * 2)),
      );
      return data is Map &&
              data['text'] is String &&
              data['sig'] is String &&
              data['checked'] is num
          ? data
          : null;
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _fromCache(Map saved) =>
      parseCatalog(utf8.encode(saved['text']), utf8.encode(saved['sig'])) ?? [];

  /// addon_store.catalog: from the cache when recent (or when looking online
  /// is off), else fetched again; [] when none verifies.
  Future<List<Map<String, dynamic>>> catalog(bool online) async {
    final now = DateTime.now().microsecondsSinceEpoch / 1e6;
    final saved = _loadCache();
    if (saved != null &&
        (!online || now - (saved['checked'] as num) < checkEvery)) {
      return _fromCache(saved);
    }
    if (!online) return [];
    List<int> text, sig;
    try {
      text = await netFetch(
        catalogUrl,
        maxBytes: maxCatalog,
        timeout: 15,
        redirects: 0,
      );
      sig = await netFetch(
        catalogSignatureUrl,
        maxBytes: 8 * 1024,
        timeout: 15,
        redirects: 0,
      );
    } on FetchError {
      return saved != null ? _fromCache(saved) : [];
    }
    final entries = parseCatalog(text, sig);
    if (entries == null) return [];
    try {
      Directory(p.dirname(cache)).createSync(recursive: true);
      posix.atomicWrite(
        cache,
        utf8.encode(
          pyJsonDumps({
            'checked': now,
            'text': utf8.decode(text),
            'sig': utf8.decode(sig),
          }),
        ),
      );
    } catch (_) {
      // a cache that cannot be written: the catalog still counts
    }
    return entries;
  }

  /// flutter_addon_catalog.installed: the verified add-ons by id.
  Map<String, Addon> installed(List<String> dirs) {
    final registry = AddonRegistry(verifier, dirs);
    final found = <String, Addon>{};
    for (final folder in registry.find()) {
      final item = verifier.verify(folder);
      if (item.id.isNotEmpty && item.state == 'verified') found[item.id] = item;
    }
    return found;
  }

  /// unpack: `<id>/…` names only (one id), no "..", no links, capped.
  String unpack(List<int> bytes, String target) {
    final data = Uint8List.fromList(bytes);
    final entries = _zipEntries(data);
    if (entries.isEmpty || entries.length > maxFiles + 4) {
      throw InstallError('too many files');
    }
    final ids = <String>{};
    var total = 0;
    for (final entry in entries) {
      final name = entry.name, parts = name.split('/');
      if (name.startsWith('/') ||
          name.contains('\\') ||
          parts
              .sublist(0, parts.length - 1)
              .any((x) => x == '' || x == '.' || x == '..') ||
          parts.last == '.' ||
          parts.last == '..' ||
          parts.length > 3) {
        throw InstallError(
          'bad name in the zip: ${String.fromCharCodes(name.runes.take(80))}',
        );
      }
      if (entry.mode & 0xf000 == 0xa000) {
        throw InstallError('links are not allowed');
      }
      ids.add(parts.first);
      total += entry.size;
      if (entry.size > maxFile || total > maxTotal) {
        throw InstallError('too large');
      }
    }
    if (ids.length != 1 || !_id.hasMatch(ids.first)) {
      throw InstallError('not one add-on folder');
    }
    final aid = ids.first;
    for (final entry in entries) {
      if (entry.isDir) continue;
      final path = p.join(target, entry.name);
      final folder = Directory(p.dirname(path));
      if (!folder.existsSync()) {
        folder.createSync(recursive: true);
      }
      final body = _zipRead(data, entry);
      if (body.length > maxFile) throw InstallError('too large');
      final fd = posix.openAt(
        -100,
        path,
        0x1 | 0x40 | 0x80 | Posix.noFollow,
        0x1a4,
      );
      try {
        posix.write(fd, body);
      } finally {
        posix.close(fd);
      }
    }
    for (final folder in [
      Directory(p.join(target, aid)),
      ...Directory(
        p.join(target, aid),
      ).listSync(recursive: true).whereType<Directory>(),
    ]) {
      posix.chmodPath(folder.path, 0x1ed);
    }
    return aid;
  }

  /// The freedesktop trash in the data folder (Gio's), else removed.
  void trash(String path) {
    try {
      final trash = p.join(p.dirname(p.dirname(p.dirname(userDir))), 'Trash');
      final files = Directory(p.join(trash, 'files'))
        ..createSync(recursive: true);
      final info = Directory(p.join(trash, 'info'))
        ..createSync(recursive: true);
      var name = p.basename(path);
      for (
        var n = 2;
        FileSystemEntity.typeSync(
              p.join(files.path, name),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound;
        n++
      ) {
        name = '${p.basename(path)}.$n';
      }
      final now = DateTime.now().toIso8601String().substring(0, 19);
      File(p.join(info.path, '$name.trashinfo')).writeAsStringSync(
        '[Trash Info]\nPath=${Uri.file(path).path}\nDeletionDate=$now\n',
      );
      Directory(path).renameSync(p.join(files.path, name));
    } catch (_) {
      try {
        Directory(path).deleteSync(recursive: true);
      } catch (_) {
        // gone already
      }
    }
  }

  /// install_bytes: unpack, verify, then replace the installed copy (the old
  /// one to the trash). Nothing changes when anything fails.
  Addon installBytes(List<int> data, {String? expect}) {
    Directory(userDir).createSync(recursive: true);
    final staging = Directory(userDir).createTempSync('.install-');
    try {
      posix.chmodPath(staging.path, 0x1ed);
      final aid = unpack(data, staging.path);
      if (expect != null && aid != expect) {
        throw InstallError('the zip holds $aid, not $expect');
      }
      final addon = verifier.verify(p.join(staging.path, aid));
      if (addon.state != 'verified') throw InstallError(addon.reason);
      final finalPath = p.join(userDir, aid);
      String? old;
      if (FileSystemEntity.typeSync(finalPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        old = p.join(
          userDir,
          '.old-$aid-${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
        );
        Directory(finalPath).renameSync(old);
      }
      Directory(p.join(staging.path, aid)).renameSync(finalPath);
      if (old != null) trash(old);
      return verifier.verify(finalPath);
    } finally {
      try {
        staging.deleteSync(recursive: true);
      } catch (_) {
        // already moved or gone
      }
    }
  }

  /// install: the zip downloaded and checked against the signed catalog.
  Future<Addon> install(Map<String, dynamic> entry) async {
    List<int> data;
    try {
      data = await netFetch(
        entry['url'] as String,
        maxBytes: math.min(entry['size'] as int, maxZip),
        timeout: 60,
        redirects: 3,
      );
    } on FetchError catch (error) {
      throw InstallError(error.message);
    }
    if (data.length != entry['size'] ||
        sha256.convert(data).toString() != entry['sha256']) {
      throw InstallError('the download does not match the catalog');
    }
    return installBytes(data, expect: entry['id'] as String);
  }

  /// install_lock: serialized beside the add-ons folder (flock, as the
  /// reference takes it).
  Future<T> locked<T>(Future<T> Function() body) async {
    final root = p.dirname(userDir);
    // mkdir(mode=0o700, parents=True): only the folder itself is private.
    if (!Directory(root).existsSync()) {
      Directory(root).createSync(recursive: true);
      posix.chmodPath(root, 0x1c0);
    }
    final st = posix.lstatOwn(root);
    if (st == null ||
        st.mode & 0xf000 != 0x4000 ||
        st.uid != posix.uid ||
        st.mode & 0x12 != 0) {
      throw StateError('Untrusted add-on storage directory');
    }
    final fd = posix.openAt(
      -100,
      p.join(root, '.catalog-install.lock'),
      0x2 | 0x40 | Posix.noFollow | Posix.cloexec,
      0x180,
    );
    try {
      final info = posix.statFull(fd);
      if (info.mode & 0xf000 != 0x8000 ||
          info.uid != posix.uid ||
          info.mode & 0x3f != 0) {
        throw StateError('Untrusted add-on installation lock');
      }
      posix.lockExclusive(fd);
      return await body();
    } finally {
      posix.close(fd);
    }
  }
}

/// flutter_addon_catalog.catalog_records: the worker's catalog answer.
Future<Map<String, dynamic>> catalogRecords(
  AddonStore store,
  bool online,
  List<String> dirs,
) async {
  final entries = await store.catalog(online);
  final known = store.installed(dirs);
  final records = <Map<String, dynamic>>[];
  var used = 0;
  for (final entry in entries.take(maxEntries)) {
    final record = {
      'entry': entry,
      'installed_version': known[entry['id']]?.version ?? '',
    };
    final size = utf8.encode(pyJsonDumps(record)).length;
    if (used + size + 4096 > 768 * 1024) break;
    used += size + 2;
    records.add(record);
  }
  return {'records': records, 'online': online};
}

/// flutter_addon_catalog._execute_locked: the reviewed entry again, then
/// installed.
Future<Map<String, dynamic>> installReviewed(
  AddonStore store,
  Map plan,
  bool online,
  List<String> dirs,
) async {
  if (!online) throw StateError('Online add-on access disabled');
  final record = plan['record'] as Map;
  final reviewed = jsonEncode(record['entry']);
  final entries = await store.catalog(true);
  final entry = entries.where((e) => jsonEncode(e) == reviewed).firstOrNull;
  if (entry == null || !supportedKinds.contains(entry['kind'])) {
    throw StateError('Catalog changed; review again');
  }
  final current = store.installed(dirs)[entry['id']];
  final version = current?.version ?? '';
  if (version != record['installed_version']) {
    throw StateError('Installed add-on changed; review again');
  }
  if (version.isNotEmpty && !newerVersion(entry['version'], version)) {
    throw StateError('Only a newer version may replace an installed add-on');
  }
  final item = await store.install(entry);
  return {'ok': true, 'id': item.id, 'version': item.version};
}

/// flutter_addon_actions: reviewed, reversible removal of the user's add-ons
/// (the app's own stay with its package).
final class AddonActions {
  AddonActions(this.posix, this.userDir);
  final Posix posix;
  final String userDir;
  static const notes = [
    'This also removes it from Asterism (GTK).',
    'After a removal, backups older than 30 days may be deleted. Active Undo backups are kept.',
  ];
  final _previews = <String, (DateTime, String, String, String)>{};
  final _undos = <String, (String, String, String, bool)>{};
  String get backups => p.join(p.dirname(userDir), 'addon-backups');

  String _token() => [
    for (var i = 0; i < 16; i++)
      math.Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  String _stamp(String path) {
    final st = posix.lstatOwn(path);
    return st == null ? '' : st.identity.join(':');
  }

  bool _isUsers(String folder) =>
      p.dirname(folder) == userDir &&
      FileSystemEntity.typeSync(folder, followLinks: false) ==
          FileSystemEntityType.directory;

  Map<String, dynamic> preview(List<Addon> items, String id) {
    final item = items.where((i) => i.id == id).firstOrNull;
    if (item == null || !_isUsers(item.folder)) {
      throw const FormatException('Only user add-ons can be removed');
    }
    final now = DateTime.now();
    _previews.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (_previews.length >= 8) {
      _previews.remove(_previews.keys.first);
    }
    final token = _token();
    _previews[token] = (now, id, item.folder, _stamp(item.folder));
    return {
      'preview': token,
      'name': item.name,
      'version': item.version,
      'notes': notes,
    };
  }

  /// prune_backups: backups older than 30 days, never one an Undo needs.
  void _prune(Set<String> keep) {
    try {
      final st = posix.lstatOwn(backups);
      if (st == null ||
          st.mode & 0xf000 != 0x4000 ||
          st.uid != posix.uid ||
          st.mode & 0x3f != 0) {
        return;
      }
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      for (final entry in Directory(
        backups,
      ).listSync(followLinks: false).take(200)) {
        if (keep.contains(entry.path) ||
            !RegExp(r'^[0-9a-f]{32}$').hasMatch(p.basename(entry.path))) {
          continue;
        }
        final info = entry.statSync();
        final own = posix.lstatOwn(entry.path);
        if (info.type == FileSystemEntityType.directory &&
            own?.uid == posix.uid &&
            info.modified.isBefore(cutoff) &&
            info.changed.isBefore(cutoff)) {
          entry.deleteSync(recursive: true);
        }
      }
    } catch (_) {
      // cleanup never turns a committed removal into a failure
    }
  }

  Map<String, dynamic> apply(
    String token,
    Set<String> enabled,
    void Function(Set<String>) reload,
    void Function(Set<String>) save,
  ) {
    final plan = _previews[token];
    if (plan == null) throw const FormatException('Unknown add-on removal');
    final (created, id, source, stamp) = plan;
    if (DateTime.now().difference(created).inSeconds >= 600) {
      throw const FormatException('Removal preview expired');
    }
    if (!_isUsers(source) || _stamp(source) != stamp) {
      throw const FormatException('Add-on changed; review again');
    }
    Directory(backups).createSync(recursive: true);
    posix.chmodPath(backups, 0x1c0);
    final st = posix.lstatOwn(backups);
    if (st == null ||
        st.mode & 0xf000 != 0x4000 ||
        st.uid != posix.uid ||
        st.mode & 0x3f != 0) {
      throw const FormatException('Unsafe backup folder');
    }
    final undo = _token(), backup = p.join(backups, undo);
    Directory(source).renameSync(backup);
    final rest = {...enabled}..remove(id);
    try {
      reload(rest);
      save(rest);
    } catch (_) {
      Directory(backup).renameSync(source);
      reload(enabled);
      rethrow;
    }
    _undos[undo] = (id, source, backup, enabled.contains(id));
    _previews.remove(token);
    _prune({for (final u in _undos.values) u.$3});
    return {'ok': true, 'undo': undo};
  }

  Map<String, dynamic> undo(
    String token,
    Set<String> enabled,
    List<Addon> Function(Set<String>) reload,
    void Function(Set<String>) save,
  ) {
    final record = _undos[token];
    if (record == null) throw const FormatException('Unknown add-on Undo');
    final (id, source, backup, wasOn) = record;
    if (FileSystemEntity.typeSync(source, followLinks: false) !=
            FileSystemEntityType.notFound ||
        FileSystemEntity.typeSync(backup, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FormatException('Add-on path is occupied');
    }
    final restored = {...enabled};
    wasOn ? restored.add(id) : restored.remove(id);
    Directory(backup).renameSync(source);
    try {
      final items = reload(restored);
      if (wasOn && !items.any((i) => i.id == id && i.state == 'loaded')) {
        throw const FormatException('Restored add-on could not be verified');
      }
      save(restored);
    } catch (_) {
      Directory(source).renameSync(backup);
      reload(enabled);
      rethrow;
    }
    _undos.remove(token);
    return {'ok': true};
  }
}
