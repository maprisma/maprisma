import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

/// One member of a tar stream, as Python's tarfile names it.
final class TarMember {
  TarMember(this.name, this.type, this.size, this.linkname);
  final String name, linkname;
  final String type; // '0' file, '1' hard link, '2' symlink, '5' folder, other
  final int size;
  bool get isFile => type == '0' || type == '\x00' || type == '7';
  bool get isDir => type == '5';
  bool get isSym => type == '2';
  bool get isLnk => type == '1';
}

/// The decompressed bytes of an archive (zstd through `zstd -dc`, as
/// `tar --zstd` uses it; gzip by dart:io; anything else as it is).
Stream<List<int>> _decompressed(String archive) async* {
  final head = <int>[];
  final raf = File(archive).openSync();
  try {
    head.addAll(raf.readSync(4));
  } finally {
    raf.closeSync();
  }
  if (head.length >= 4 &&
      head[0] == 0x28 &&
      head[1] == 0xb5 &&
      head[2] == 0x2f &&
      head[3] == 0xfd) {
    final process = await Process.start('zstd', ['-dc', '--', archive]);
    unawaited(process.stdin.close());
    unawaited(process.stderr.drain<void>());
    yield* process.stdout;
    if (await process.exitCode != 0) {
      throw StateError('not a readable archive: zstd failed');
    }
    return;
  }
  final source = File(archive).openRead();
  if (head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b) {
    yield* source.transform(gzip.decoder);
  } else {
    yield* source;
  }
}

int _octal(List<int> field) {
  if (field.isNotEmpty && field[0] & 0x80 != 0) {
    // GNU base-256 for large sizes.
    var value = field[0] & 0x7f;
    for (final b in field.skip(1)) {
      value = value * 256 + b;
    }
    return value;
  }
  final text = ascii
      .decode(field.where((b) => b != 0).toList(), allowInvalid: true)
      .trim();
  return text.isEmpty ? 0 : int.parse(text, radix: 8);
}

String _cString(List<int> field) {
  final end = field.indexOf(0);
  return utf8.decode(
    end < 0 ? field : field.sublist(0, end),
    allowMalformed: true,
  );
}

Map<String, String> _pax(List<int> data) {
  final found = <String, String>{};
  var at = 0;
  while (at < data.length) {
    final space = data.indexOf(32, at);
    if (space < 0) break;
    final length = int.tryParse(ascii.decode(data.sublist(at, space)));
    if (length == null || length <= 0 || at + length > data.length) break;
    final record = utf8.decode(
      data.sublist(space + 1, at + length - 1),
      allowMalformed: true,
    );
    final eq = record.indexOf('=');
    if (eq > 0) found[record.substring(0, eq)] = record.substring(eq + 1);
    at += length;
  }
  return found;
}

/// The members of a tar archive, read as a stream (nothing written).
Stream<TarMember> tarMembers(String archive) async* {
  final buffer = BytesBuilder(copy: false);
  var pending = Uint8List(0);
  String? longName, longLink;
  Map<String, String> pax = {};
  // A small reader over the decompressed stream.
  final chunks = StreamIterator(_decompressed(archive));
  var consumed = 0;
  // n bytes; null when the stream ends first (partial: what was left goes).
  Future<Uint8List?> take(int n) async {
    while (pending.length < n) {
      if (!await chunks.moveNext()) {
        pending = Uint8List(0);
        return null;
      }
      buffer
        ..add(pending)
        ..add(chunks.current);
      pending = buffer.takeBytes();
    }
    final out = Uint8List.sublistView(pending, 0, n);
    pending = Uint8List.fromList(Uint8List.sublistView(pending, n));
    consumed += n;
    return out;
  }

  bool checksumOk(Uint8List header) {
    int? stored;
    try {
      stored = _octal(header.sublist(148, 156));
    } on FormatException {
      return false;
    }
    var unsigned = 0, signed = 0;
    for (var i = 0; i < 512; i++) {
      final b = i >= 148 && i < 156 ? 32 : header[i];
      unsigned += b;
      signed += b >= 128 ? b - 256 : b;
    }
    return stored == unsigned || stored == signed;
  }

  try {
    while (true) {
      // tarfile.next: at the start an empty, short or bad header is an
      // error; later a short or bad header (or a zero block) ends the archive.
      final at = consumed;
      final header = await take(512);
      if (header == null) {
        if (at == 0) throw StateError('not a readable archive: empty file');
        break;
      }
      if (header.every((b) => b == 0)) break; // end of archive
      if (!checksumOk(header)) {
        if (at == 0) throw StateError('not a readable archive: bad checksum');
        break;
      }
      final type = String.fromCharCode(header[156]);
      final size = _octal(header.sublist(124, 136));
      final padded = (size + 511) ~/ 512 * 512;
      var name = _cString(header.sublist(0, 100));
      var linkname = _cString(header.sublist(157, 257));
      if (ascii.decode(header.sublist(257, 262), allowInvalid: true) ==
          'ustar') {
        final prefix = _cString(header.sublist(345, 500));
        if (prefix.isNotEmpty) name = '$prefix/$name';
      }
      if (type == 'L' || type == 'K' || type == 'x' || type == 'g') {
        final body = await take(padded);
        if (body == null) {
          throw StateError('not a readable archive: unexpected end of data');
        }
        final data = body.sublist(0, size);
        if (type == 'L') longName = _cString(data);
        if (type == 'K') longLink = _cString(data);
        if (type == 'x') pax = _pax(data);
        continue;
      }
      name = pax['path'] ?? longName ?? name;
      linkname = pax['linkpath'] ?? longLink ?? linkname;
      final realSize = int.tryParse(pax['size'] ?? '') ?? size;
      longName = longLink = null;
      pax = {};
      // Contents of files are skipped; links and folders hold none.
      final skip = type == '0' || type == '\x00' || type == '7'
          ? (realSize + 511) ~/ 512 * 512
          : padded;
      var left = skip;
      while (left > 0) {
        final part = await take(left > 1 << 20 ? 1 << 20 : left);
        if (part == null) {
          throw StateError('not a readable archive: unexpected end of data');
        }
        left -= part.length;
      }
      yield TarMember(name, type, realSize, linkname);
    }
  } finally {
    await chunks.cancel();
  }
}

/// install_ctl.check_archive: before anything is unpacked, the archive's
/// entries must add up to at most `limit` bytes and `maxEntries` entries;
/// names and link targets must stay inside the folder (no absolute path, no
/// "..", no device or pipe), and nothing may lead through one of the
/// archive's own links.
Future<void> checkArchive(
  String archive, {
  int limit = 20 * 1024 * 1024 * 1024,
  int maxEntries = 200000,
}) async {
  Stream<TarMember> members() async* {
    var count = 0;
    await for (final m in tarMembers(archive)) {
      if (++count > maxEntries) {
        throw StateError('the archive holds too many files');
      }
      yield m;
    }
  }

  String norm(String path) => path.isEmpty ? '.' : p.posix.normalize(path);
  final links = <String>{};
  await for (final m in members()) {
    if (m.isSym) links.add(norm(m.name.replaceFirst(RegExp(r'/+$'), '')));
  }
  bool throughLink(String path) {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      if (links.contains(parts.sublist(0, i).join('/'))) return true;
    }
    return false;
  }

  String? walk(List<String> start, String target) {
    final here = [...start];
    final names = target.split('/').where((x) => x != '' && x != '.').toList();
    for (var i = 0; i < names.length; i++) {
      final part = names[i];
      if (part == '..') {
        if (here.isEmpty) return null;
        here.removeLast();
        continue;
      }
      here.add(part);
      if (i < names.length - 1 && links.contains(here.join('/'))) return null;
    }
    return here.join('/');
  }

  String cut(String text) => String.fromCharCodes(text.runes.take(80));
  var total = 0;
  await for (final m in members()) {
    var name = m.name.replaceFirst(RegExp(r'/+$'), '');
    if (name.startsWith('/') || name.split('/').contains('..')) {
      throw StateError(
        'the archive names a path outside its folder: ${cut(name)}',
      );
    }
    name = norm(name);
    if (throughLink(name)) {
      throw StateError(
        'the archive writes through one of its links: ${cut(name)}',
      );
    }
    if (m.isSym || m.isLnk) {
      if (m.linkname.startsWith('/')) {
        throw StateError('the archive links outside its folder: ${cut(name)}');
      }
      final parts = name.split('/');
      final start = m.isSym ? parts.sublist(0, parts.length - 1) : <String>[];
      final target = walk(start, m.linkname);
      if (target == null ||
          m.isLnk && (target.isEmpty || links.contains(target))) {
        throw StateError(
          'the archive links outside its folder or through a link: ${cut(name)}',
        );
      }
    } else if (!(m.isFile || m.isDir)) {
      throw StateError('the archive holds a device or pipe: ${cut(name)}');
    }
    total += m.size < 0 ? 0 : m.size;
    if (total > limit) {
      throw StateError('the archive unpacks to more than the release limit');
    }
  }
}
