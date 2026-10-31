import 'dart:io';
import 'package:maprisma_core/src/addon_hints.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('addon-hints'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('present: a program on PATH or a folder in the home', () {
    final bin = Directory('${dir.path}/bin')..createSync();
    File('${bin.path}/goose').writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['755', '${bin.path}/goose']);
    Directory('${dir.path}/.jan').createSync();
    expect(
      addonPresent(
        {
          'commands': ['goose'],
        },
        dir.path,
        bin.path,
      ),
      isTrue,
    );
    expect(
      addonPresent(
        {
          'commands': ['none'],
          'paths': ['~/.jan'],
        },
        dir.path,
        bin.path,
      ),
      isTrue,
    );
    expect(
      addonPresent(
        {
          'commands': ['none'],
          'paths': ['~/.missing', '/etc'],
        },
        dir.path,
        bin.path,
      ),
      isFalse,
    );
  });

  test('off, new and updates, with plurals', () {
    final rows = <Map<String, dynamic>>[
      {'id': 'agent-goose', 'name': 'Goose', 'kind': 'agent', 'present': true},
      {'id': 'agent-amp', 'name': 'Amp', 'kind': 'agent', 'present': true},
      {'id': 'llm-jan', 'name': 'Jan', 'kind': 'provider', 'present': true},
      {'id': 'agent-on', 'name': 'On', 'kind': 'agent', 'present': true},
      {'id': 'feat', 'name': 'Feature', 'kind': 'feature', 'present': true},
      {'id': 'agent-gone', 'name': 'Gone', 'kind': 'agent', 'present': false},
      {
        'id': 'agent-on',
        'name': 'On',
        'kind': 'agent',
        'action': 'update',
        'version': '1.2.0',
        'installed_version': '1.1.0',
        'preview': 'p1',
      },
      {'id': 'x', 'name': 'X', 'action': 'update', 'preview': null},
    ];
    final lines = addonHints(
      rows,
      {'agent-amp': 'verified', 'agent-on': 'loaded'},
      (t) => t,
      (one, other, n) => n == 1 ? one : other,
    );
    expect([for (final l in lines) l['kind']], ['off', 'new', 'updates']);
    expect(lines[0]['text'], 'Amp is on this PC but not on the map');
    expect(lines[0]['column'], 'agents');
    expect(lines[1]['text'], 'Goose, Jan are on this PC but not on the map');
    expect(lines[1]['ids'], ['agent-goose', 'llm-jan']);
    expect(lines[1]['column'], 'agents');
    expect(lines[2]['column'], 'agents');
    expect(lines[2]['text'], 'Add-on updates ready: On');
    expect((lines[2]['updates'] as List).single, {
      'id': 'agent-on',
      'name': 'On',
      'version': '1.2.0',
      'current': '1.1.0',
      'preview': 'p1',
    });
    expect(addonHints(const [], const {}, (t) => t, (a, b, n) => a), isEmpty);
  });
}
