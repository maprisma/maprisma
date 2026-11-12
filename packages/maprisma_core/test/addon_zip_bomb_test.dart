import 'dart:io';
import 'dart:typed_data';
import 'package:maprisma_core/src/addon_store.dart';
import 'package:maprisma_core/src/addons.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:test/test.dart';

/// One zip entry: its name, the raw deflate (or stored) bytes, the method and
/// the uncompressed size its headers declare (which may lie).
typedef _Entry = ({String name, List<int> body, int method, int declared});

/// Raw deflate of [zeros] zero bytes, encoded in 1 MiB steps so building a
/// bomb never holds its inflated size in memory.
List<int> _deflatedZeros(int zeros) {
  final out = BytesBuilder(copy: false);
  final sink = ZLibEncoder(
    raw: true,
    level: 9,
  ).startChunkedConversion(_Collect(out));
  final block = Uint8List(1024 * 1024);
  for (var left = zeros; left > 0; left -= block.length) {
    sink.add(left >= block.length ? block : Uint8List(left));
  }
  sink.close();
  return out.takeBytes();
}

final class _Collect implements Sink<List<int>> {
  _Collect(this.out);
  final BytesBuilder out;
  @override
  void add(List<int> data) => out.add(data);
  @override
  void close() {}
}

/// A minimal zip (local headers, central directory, end record); CRCs are 0
/// because unpack does not get as far as checking them for these cases.
Uint8List _zip(List<_Entry> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  ByteData le(int n) => ByteData(n);
  for (final e in entries) {
    final name = e.name.codeUnits, offset = out.length;
    final local = le(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, e.method, Endian.little)
      ..setUint32(18, e.body.length, Endian.little)
      ..setUint32(22, e.declared, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(e.body);
    final dir = le(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 0x31e, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, e.method, Endian.little)
      ..setUint32(20, e.body.length, Endian.little)
      ..setUint32(24, e.declared, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(38, 0x81a4 << 16, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(dir.buffer.asUint8List())
      ..add(name);
  }
  final at = out.length, size = central.length;
  out.add(central.takeBytes());
  final end = le(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, size, Endian.little)
    ..setUint32(16, at, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

void main() {
  late Directory temp;
  late AddonStore store;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('maprisma-zip-bomb-');
    store = AddonStore(
      Posix(),
      '${temp.path}/addons',
      temp.path,
      AddonVerifier(Posix()),
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Matcher refused(String reason) => throwsA(
    isA<InstallError>().having((e) => '$e', 'reason', contains(reason)),
  );

  test('a lying header cannot make the preview inflate a bomb', () {
    // 256 MiB of zeros declared as 100 bytes, well under the 8 MiB input cap.
    final bomb = _zip([
      (
        name: 'agent-bomb/addon.json',
        body: _deflatedZeros(256 * 1024 * 1024),
        method: 8,
        declared: 100,
      ),
    ]);
    expect(bomb.length, lessThan(maxZip));
    final path = '${temp.path}/bomb.zip';
    File(path).writeAsBytesSync(bomb);
    final before = ProcessInfo.maxRss;
    expect(
      () => AddonFileImports(() => 't').preview(path, store, []),
      refused('too large'),
    );
    // Inflating stopped near maxFile: far less than the 256 MiB it holds.
    expect(ProcessInfo.maxRss - before, lessThan(64 * 1024 * 1024));
    expect(Directory('${temp.path}/addons').existsSync(), isFalse);
  });

  test('a high-ratio entry declared honestly is refused before inflating', () {
    final bomb = _zip([
      (
        name: 'agent-bomb/addon.json',
        body: _deflatedZeros(3 * 1024 * 1024),
        method: 8,
        declared: 3 * 1024 * 1024,
      ),
    ]);
    expect(
      () => store.unpack(bomb, '${temp.path}/staging'),
      refused('too large'),
    );
  });

  test('small declared sizes cannot add up past the total budget', () {
    // Four honest entries fill the total budget up to 40 bytes; the fifth
    // declares 10 bytes but inflates to almost 1 MiB. It must be cut off at
    // the remaining 40 bytes while inflating ("too large"), not only after
    // inflating its full output (which would be the header mismatch).
    final full = maxFile - 10;
    final bomb = _zip([
      for (var i = 0; i < 4; i++)
        (
          name: 'agent-bomb/f$i',
          body: _deflatedZeros(full),
          method: 8,
          declared: full,
        ),
      (
        name: 'agent-bomb/f4',
        body: _deflatedZeros(maxFile - 1),
        method: 8,
        declared: 10,
      ),
    ]);
    expect(
      () => store.unpack(bomb, '${temp.path}/staging'),
      refused('too large'),
    );
  });

  test('an entry whose real size differs from its header is refused', () {
    final bomb = _zip([
      (
        name: 'agent-bomb/addon.json',
        body: _deflatedZeros(2000),
        method: 8,
        declared: 1000,
      ),
    ]);
    expect(
      () => store.unpack(bomb, '${temp.path}/staging'),
      refused('not a zip file'),
    );
  });

  test('a stored entry larger than one file is refused', () {
    final bomb = _zip([
      (
        name: 'agent-bomb/addon.json',
        body: Uint8List(maxFile + 1),
        method: 0,
        declared: 10,
      ),
    ]);
    expect(
      () => store.unpack(bomb, '${temp.path}/staging'),
      refused('too large'),
    );
  });

  test('a matching entry is still unpacked', () {
    final ok = _zip([
      (
        name: 'agent-ok/addon.json',
        body: _deflatedZeros(4096),
        method: 8,
        declared: 4096,
      ),
    ]);
    final staging = '${temp.path}/staging';
    expect(store.unpack(ok, staging), 'agent-ok');
    expect(File('$staging/agent-ok/addon.json').lengthSync(), 4096);
  });
}
