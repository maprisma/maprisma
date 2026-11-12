import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/window_size.dart';

void main() {
  test('the path follows XDG_CONFIG_HOME like the core', () {
    expect(windowSizePath({'HOME': '/h'}), '/h/.config/maprisma/window.json');
    expect(
      windowSizePath({'HOME': '/h', 'XDG_CONFIG_HOME': '/x'}),
      '/x/maprisma/window.json',
    );
    expect(
      windowSizePath({'HOME': '/h', 'XDG_CONFIG_HOME': 'rel'}),
      '/h/.config/maprisma/window.json',
    );
  });

  test('parse keeps sane sizes only', () {
    expect(
      WindowSizeStore.parse({'width': 1200, 'height': 800}),
      const Size(1200, 800),
    );
    expect(
      WindowSizeStore.parse({'width': 99999, 'height': 800}),
      const Size(8192, 800),
    );
    expect(WindowSizeStore.parse({'width': 100, 'height': 800}), isNull);
    expect(WindowSizeStore.parse({'width': '1200', 'height': 800}), isNull);
    expect(WindowSizeStore.parse([1200, 800]), isNull);
  });

  test('a resize is saved after the delay; broken files are ignored', () async {
    final dir = Directory.systemTemp.createTempSync('window-size');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/sub/window.json';
    final store = WindowSizeStore(
      path,
      delay: const Duration(milliseconds: 20),
    );
    expect(store.load(), isNull);
    store.resized(const Size(900, 700));
    store.resized(const Size(1000, 750));
    store.resized(const Size(100, 100)); // too small: not taken
    expect(File(path).existsSync(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(jsonDecode(File(path).readAsStringSync()), {
      'width': 1000,
      'height': 750,
    });
    expect(store.load(), const Size(1000, 750));
    File(path).writeAsStringSync('not json');
    expect(store.load(), isNull);
  });
}
