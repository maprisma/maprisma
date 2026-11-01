import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Whatever changes the setup must reach the map, also from out of its sight:
/// each such call in the app has `_mapStale` or `_runTask` beside it.
void main() {
  test('every change the app makes marks the map', () {
    final source = File('lib/main.dart').readAsStringSync();
    final methods = source.split(
      RegExp(r'\n  (?=(?:Future|void|bool) ?[<_a-zA-Z])'),
    );
    final change = RegExp(
      r'_client\s*\.\s*(\w*(?:Apply|Undo|Install|SetEnabled|Reload|Update|Stop|Start|Remove)\w*)\(',
    );
    final missing = <String>[];
    for (final method in methods) {
      for (final call in change.allMatches(method)) {
        final name = call[1]!;
        if (name.contains('Preview')) continue;
        // A started agent shows by itself; settings do not change the setup.
        if (const {'sessionsStart', 'settingsUpdate'}.contains(name)) continue;
        if (!method.contains('_mapStale') && !method.contains('_runTask(')) {
          missing.add(name);
        }
      }
    }
    expect(missing, isEmpty);
  });
}
