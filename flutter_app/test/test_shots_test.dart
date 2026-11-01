import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/test_shots.dart';

void main() {
  test(
    'window pictures: Pictures/Maprisma, dated, never overwritten',
    () async {
      final home = Directory.systemTemp.createTempSync('shots-home');
      addTearDown(() => home.deleteSync(recursive: true));
      final shots = WindowShots.fromEnvironment({'HOME': home.path});
      final time = DateTime(2026, 11, 1, 8, 26, 31);
      final first = await shots.save(Uint8List.fromList([1]), time);
      final second = await shots.save(Uint8List.fromList([2]), time);
      expect(
        first,
        '${home.path}/Pictures/Maprisma/maprisma-2026-11-01-08-26-31.png',
      );
      expect(second, endsWith('-08-26-31-2.png'));
    },
  );

  test('a note goes next to its picture; no note, no file', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final shots = WindowShots('${home.path}/shots');
    final picture = await shots.save(
      Uint8List.fromList([1]),
      DateTime(2026, 11, 1, 8, 26, 31),
    );
    await shots.note(picture, '  ');
    expect(File(picture.replaceAll('.png', '.txt')).existsSync(), isFalse);
    await shots.note(picture, ' The header is cut off ');
    expect(
      File(picture.replaceAll('.png', '.txt')).readAsStringSync(),
      'The header is cut off\n',
    );
  });

  late Directory run;
  setUp(() => run = Directory.systemTemp.createTempSync('maprisma-shots-'));
  tearDown(() => run.deleteSync(recursive: true));

  test('only a recorded test has screenshots', () {
    expect(TestShots.fromEnvironment({}), isNull);
    expect(TestShots.fromEnvironment({'MAPRISMA_RECORD_PROTOCOL': ''}), isNull);
    expect(
      TestShots.fromEnvironment({
        'MAPRISMA_RECORD_PROTOCOL': '/a/protocol.jsonl',
      })!.folder,
      '/a/shots',
    );
  });

  test('pictures get the time as name and never overwrite', () async {
    final shots = TestShots('${run.path}/protocol.jsonl');
    final time = DateTime(2026, 10, 31, 8, 26, 31);
    final first = await shots.save(Uint8List.fromList([1]), time);
    final second = await shots.save(Uint8List.fromList([2]), time);
    expect(first.split('/').last, '08-26-31.png');
    expect(second.split('/').last, '08-26-31-2.png');
    expect(File(first).readAsBytesSync(), [1]);
  });

  test('the protocol gets the file and the note', () async {
    final protocol = '${run.path}/protocol.jsonl';
    File(protocol).writeAsStringSync('{"method":"app.snapshot"}\n');
    final shots = TestShots(protocol);
    final time = DateTime(2026, 10, 31, 8, 26, 31);
    await shots.record('${shots.folder}/08-26-31.png', 'white bar', time);
    final line = jsonDecode(File(protocol).readAsLinesSync().last);
    expect(line['method'], 'test.shot');
    expect(line['params'], {'file': 'shots/08-26-31.png', 'note': 'white bar'});
    expect(line['time'], time.toIso8601String());
  });
}
