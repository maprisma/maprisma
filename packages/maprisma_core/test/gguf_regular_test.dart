import 'dart:io';

import 'package:maprisma_core/src/connect_apply.dart' show ConfigFiles;
import 'package:maprisma_core/src/context.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late ScanFiles files;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('maprisma-gguf-');
    files = ScanFiles(AppIdentity(environment: {'HOME': dir.path, 'PATH': '/usr/bin'}));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('a FIFO named .gguf returns at once and is no model', () {
    final fifo = '${dir.path}/blocked.gguf';
    Process.runSync('mkfifo', [fifo]);
    final watch = Stopwatch()..start();
    expect(() => readGguf(fifo), throwsFormatException);
    expect(watch.elapsedMilliseconds, lessThan(1000));
    expect(ProviderScans(files).ggufFiles(dir.path), isEmpty);
    final context = ContextReader(files, ConfigFiles(files.posix, dir.path));
    expect(context.llamaModelFile(dir.path, 'blocked'), isNull);
  });

  test('a regular file and a link to one still read', () {
    File('${dir.path}/m.gguf').writeAsStringSync('GGUF');
    Link('${dir.path}/l.gguf').createSync('${dir.path}/m.gguf');
    for (final path in ['${dir.path}/m.gguf', '${dir.path}/l.gguf']) {
      final file = openRegular(path);
      expect(String.fromCharCodes(file.readSync(4)), 'GGUF');
      file.closeSync();
    }
    expect(
      ProviderScans(files).ggufFiles(dir.path).map((f) => f.split('/').last).toList()..sort(),
      ['l.gguf', 'm.gguf'],
    );
    final context = ContextReader(files, ConfigFiles(files.posix, dir.path));
    expect(context.llamaModelFile(dir.path, 'm'), '${dir.path}/m.gguf');
  });
}
