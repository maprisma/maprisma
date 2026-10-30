import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/adapter_assets.g.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';

void main() {
  test('all shipped adapters parse and their keys remain strictly typed', () {
    final adapters = builtinAdapters();
    expect(adapters.length, builtinAdapterSources.length);
    expect(adapters.map((a) => a.command).toSet().length, adapters.length);
    for (final a in adapters) {
      expect(a.icon, isA<String>());
    }
    const base = {'command': 'test-agent', 'name': 'Test Agent'};
    for (final e in (adapterSchema['TOP'] as Map).entries) {
      final wrong = switch (e.value) {
        'text' => true,
        'true/false' => 'yes',
        'a list of texts' => [1],
        'a table' => [],
        'tables' => [1],
        _ => null,
      };
      expect(
        () => Adapter({...base, e.key: wrong}),
        throwsA(isA<AdapterError>()),
        reason: e.key,
      );
    }
    expect(
      () => Adapter({...base, 'unknown': 1}),
      throwsA(isA<AdapterError>()),
    );
  });
  test(
    'prompt/configure declarations never select a shell or embedded template',
    () {
      for (final data in [
        {
          'ask': {
            'argv': ['sh', '{prompt}'],
          },
        },
        {
          'ask': {
            'argv': ['x', 'embedded{prompt}'],
          },
        },
        {
          'configure': [
            {
              'label': 'bad',
              'argv': ['sh'],
            },
          ],
        },
        {
          'start': ['\x00'],
        },
        {
          'closed': {'home_env': 'x=y'},
        },
        {
          'advise': {
            'argv': ['x'],
            'model': ['--model', '{model}'],
          },
        },
      ]) {
        expect(
          () => Adapter({'command': 'x', 'name': 'X', ...data}),
          throwsA(isA<AdapterError>()),
        );
      }
    },
  );
  test(
    'bounded adapter read refuses links FIFOs malformed UTF8 and huge files',
    () {
      final home = Directory.systemTemp.createTempSync(
        'maprisma-adapter-test-',
      );
      try {
        final file = File('${home.path}/a.toml')
          ..writeAsStringSync('command="x"\nname="X"');
        expect(Adapter.load(file.path).command, 'x');
        Link('${home.path}/link.toml').createSync(file.path);
        expect(
          () => Adapter.load('${home.path}/link.toml'),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          Process.runSync('/usr/bin/mkfifo', [
            '${home.path}/fifo.toml',
          ]).exitCode,
          0,
        );
        expect(
          () => Adapter.load('${home.path}/fifo.toml'),
          throwsA(isA<FileSystemException>()),
        );
        file.writeAsBytesSync([255, 254]);
        expect(() => Adapter.load(file.path), throwsFormatException);
        file.writeAsStringSync('x' * (adapterMaxBytes + 1));
        expect(
          () => Adapter.load(file.path),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );
  test(
    'scan files cap reads and directory enumeration without creating files',
    () {
      final home = Directory.systemTemp.createTempSync('maprisma-scan-test-');
      try {
        final io = ScanFiles(AppIdentity(environment: {'HOME': home.path}));
        expect(io.list('~/missing'), isEmpty);
        expect(home.listSync(), isEmpty);
        for (var i = 0; i < 20; i++) {
          File('${home.path}/f$i').writeAsStringSync('12345');
        }
        expect(io.list('~', limit: 3).length, 3);
        expect(io.text('~/f0', limit: 4), null);
        Link('${home.path}/linked').createSync('${home.path}/f0');
        expect(io.text('~/linked'), null);
        expect(io.text('~/auth.json'), null);
        expect(io.json('~/missing'), isEmpty);
      } finally {
        home.deleteSync(recursive: true);
      }
    },
  );
}
