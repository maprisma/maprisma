import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:maprisma_core/src/installers.dart';
import 'package:maprisma_core/src/model_downloads.dart' show ModelFiles;
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final posix = Posix();
  setUp(() => root = Directory.systemTemp.createTempSync('maprisma-trust-'));
  tearDown(() {
    Process.runSync('chmod', ['-R', 'u+rwx', root.path]);
    root.deleteSync(recursive: true);
  });

  void chmod(String path, String mode) => Process.runSync('chmod', [mode, path]);

  test('private folders, missing parts: fine', () {
    checkTrusted(root.path);
    checkTrusted('${root.path}/new/deeper');
  });

  test('a program folder others can write is refused, sticky or not', () {
    final shared = Directory('${root.path}/shared')..createSync();
    for (final mode in ['775', '777', '1777']) {
      chmod(shared.path, mode);
      expect(() => checkTrusted(shared.path), throwsStateError);
    }
  });

  test('a writable folder above needs the sticky bit', () {
    final parent = '${root.path}/parent';
    Directory('$parent/prog').createSync(recursive: true);
    chmod(parent, '777');
    expect(() => checkTrusted('$parent/prog'), throwsStateError);
    expect(() => checkTrusted('$parent/other'), throwsStateError);
    chmod(parent, '1777');
    checkTrusted('$parent/prog');
  });

  test('links on the way are followed and checked; the folder itself no link', () {
    Directory('${root.path}/real/prog').createSync(recursive: true);
    Link('${root.path}/theirs').createSync('${root.path}/real');
    Link('${root.path}/mine').createSync('${root.path}/theirs');
    checkTrusted('${root.path}/mine/prog');
    expect(() => checkTrusted('${root.path}/mine'), throwsStateError);
    Directory('${root.path}/b').createSync();
    Link('${root.path}/b/up').createSync('../real');
    checkTrusted('${root.path}/b/up/prog');
    chmod('${root.path}/real', '777');
    expect(() => checkTrusted('${root.path}/b/up/prog'), throwsStateError);
    expect(() => checkTrusted('${root.path}/a/../b'), throwsStateError);
  });

  test('the verified file keeps its bytes when the name is swapped', () {
    final file = File('${root.path}/release.tar.zst')..writeAsStringSync('verified bytes');
    final digest = sha256.convert(utf8.encode('verified bytes')).toString();
    final fd = openVerified(ModelFiles(posix), file.path, digest);
    try {
      File('${root.path}/evil').writeAsStringSync('other bytes');
      File('${root.path}/evil').renameSync(file.path);
      expect(File('/proc/$pid/fd/$fd').readAsStringSync(), 'verified bytes');
    } finally {
      posix.close(fd);
    }
  });

  test('wrong bytes, a link or a file others can write: refused', () {
    final file = File('${root.path}/a')..writeAsStringSync('x');
    final digest = sha256.convert(utf8.encode('x')).toString();
    expect(
      () => openVerified(ModelFiles(posix), file.path, sha256.convert([1]).toString()),
      throwsStateError,
    );
    Link('${root.path}/b').createSync(file.path);
    expect(() => openVerified(ModelFiles(posix), '${root.path}/b', digest), throwsStateError);
    chmod(file.path, '666');
    expect(() => openVerified(ModelFiles(posix), file.path, digest), throwsStateError);
  });
}
