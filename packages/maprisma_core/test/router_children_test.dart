import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:test/test.dart';

/// llama.cpp's router starts a server per model on a port of its own: the
/// router stays the address, as in inventory.llamacpp.
void main() {
  // The folder lists its entries in no fixed order: both ways round, so the
  // router's model is seen last in one of them.
  for (final childFirst in [false, true]) {
    test('a model the router started does not take its address '
        '(child first: $childFirst)', () {
      final temp = Directory.systemTemp.createTempSync('maprisma-router-');
      addTearDown(() => temp.deleteSync(recursive: true));
      Directory('${temp.path}/bin').createSync();
      File('${temp.path}/bin/llama-server').writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', '${temp.path}/bin/llama-server']);
      void process(int pid, int parent, List<String> argv) {
        final dir = Directory('${temp.path}/proc/$pid')
          ..createSync(recursive: true);
        File('${dir.path}/comm').writeAsStringSync('llama-server\n');
        File(
          '${dir.path}/cmdline',
        ).writeAsStringSync('${argv.join('\x00')}\x00');
        File(
          '${dir.path}/stat',
        ).writeAsStringSync('$pid (llama-server) S $parent 0 0 0');
        File('${dir.path}/environ').writeAsStringSync('');
      }

      void router() => process(100, 1, ['llama-server', '--port', '8080']);
      void child() => process(200, 100, [
        'llama-server',
        '--port',
        '39123',
        '-m',
        '/m/a.gguf',
      ]);
      if (childFirst) {
        child();
        router();
      } else {
        router();
        child();
      }
      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'generic',
          'MAPRISMA_SCAN_PROC': '${temp.path}/proc',
        },
      );
      final rt = core.reads.inventory
          .collect(core.reads.catalog.scan(), remember: false)
          .runtimes
          .singleWhere((r) => r.key == 'llamacpp');
      expect(rt.running, isTrue);
      expect(rt.address, endsWith(':8080'));
    });
  }
}
