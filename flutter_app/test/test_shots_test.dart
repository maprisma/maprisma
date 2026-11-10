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

  test(
    'a chosen folder is used; one that cannot be written loses nothing',
    () async {
      final home = Directory.systemTemp.createTempSync('shots-home');
      addTearDown(() => home.deleteSync(recursive: true));
      final shots = WindowShots('${home.path}/default');
      final time = DateTime(2026, 11, 1, 8, 26, 31);
      final png = Uint8List.fromList([1]);
      expect(
        await shots.saveTo('${home.path}/mine', png, time),
        startsWith('${home.path}/mine/'),
      );
      File('${home.path}/a-file').writeAsStringSync('');
      expect(
        await shots.saveTo('${home.path}/a-file', png, time),
        startsWith('${home.path}/default/'),
      );
      expect(
        await shots.saveTo(null, png, time),
        startsWith('${home.path}/default/'),
      );
    },
  );

  test('the folder is private (0700), each file 0600', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final shots = WindowShots('${home.path}/Pictures/Maprisma');
    final picture = await shots.save(
      Uint8List.fromList([1, 2, 3]),
      DateTime(2026, 11, 1, 8, 26, 31),
    );
    await shots.note(picture, 'cut off');
    expect(FileStat.statSync(shots.folder).mode & 0x1ff, 0x1c0);
    expect(FileStat.statSync(picture).mode & 0x1ff, 0x180);
    expect(
      FileStat.statSync(picture.replaceAll('.png', '.txt')).mode & 0x1ff,
      0x180,
    );
    expect(File(picture).readAsBytesSync(), [1, 2, 3]);
  });

  test('a link or a file in the folder\'s place, or a folder others may '
      'write to, is refused', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final png = Uint8List.fromList([1]), time = DateTime(2026, 11, 1);
    Directory('${home.path}/real').createSync();
    Link('${home.path}/link').createSync('${home.path}/real');
    await expectLater(
      WindowShots('${home.path}/link').save(png, time),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory('${home.path}/real').listSync(), isEmpty);
    File('${home.path}/file').writeAsStringSync('');
    await expectLater(
      WindowShots('${home.path}/file').save(png, time),
      throwsA(isA<FileSystemException>()),
    );
    final open = Directory('${home.path}/open')..createSync();
    Process.runSync('chmod', ['777', open.path]);
    await expectLater(
      WindowShots(open.path).save(png, time),
      throwsA(isA<FileSystemException>()),
    );
    expect(open.listSync(), isEmpty);
  });

  test('a name with a picture, a note or a dangling link is taken', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final shots = WindowShots('${home.path}/shots');
    final time = DateTime(2026, 11, 1, 8, 26, 31);
    Directory(shots.folder).createSync();
    Process.runSync('chmod', ['700', shots.folder]);
    File(
      '${shots.folder}/maprisma-2026-11-01-08-26-31.txt',
    ).writeAsStringSync('old');
    Link(
      '${shots.folder}/maprisma-2026-11-01-08-26-31-2.png',
    ).createSync('${home.path}/nowhere');
    final path = await shots.save(Uint8List.fromList([1]), time);
    expect(path, endsWith('-08-26-31-3.png'));
    expect(File('${home.path}/nowhere').existsSync(), isFalse);
    expect(
      File(
        '${shots.folder}/maprisma-2026-11-01-08-26-31.txt',
      ).readAsStringSync(),
      'old',
    );
  });

  test('a note is never written over an existing one and is bounded', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final shots = WindowShots('${home.path}/shots');
    final picture = await shots.save(
      Uint8List.fromList([1]),
      DateTime(2026, 11, 1, 8, 26, 31),
    );
    final note = File(picture.replaceAll('.png', '.txt'));
    await shots.note(picture, 'x' * (screenshotNoteLimit + 50));
    expect(note.readAsStringSync().length, screenshotNoteLimit + 1);
    await expectLater(
      shots.note(picture, 'second'),
      throwsA(isA<FileSystemException>()),
    );
    expect(note.readAsStringSync(), startsWith('xxx'));
  });

  test('a write that fails leaves nothing half-written', () async {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    addTearDown(() => debugFailWriteAfter = null);
    final shots = WindowShots('${home.path}/shots');
    debugFailWriteAfter = 2;
    await expectLater(
      shots.save(Uint8List.fromList([1, 2, 3, 4]), DateTime(2026, 11, 1)),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(shots.folder).listSync(), isEmpty);
  });

  test('the pictures folder: user-dirs.dirs read safely, else ~/Pictures', () {
    final home = Directory.systemTemp.createTempSync('shots-home');
    addTearDown(() => home.deleteSync(recursive: true));
    final env = {'HOME': home.path};
    expect(
      WindowShots.fromEnvironment(env).folder,
      '${home.path}/Pictures/Maprisma',
    );
    final config = Directory('${home.path}/.config')..createSync();
    final dirs = File('${config.path}/user-dirs.dirs');
    dirs.writeAsStringSync('XDG_PICTURES_DIR="\$HOME/Bilder"\n');
    expect(
      WindowShots.fromEnvironment(env).folder,
      '${home.path}/Bilder/Maprisma',
    );
    dirs.writeAsStringSync('XDG_PICTURES_DIR="\$HOME/"\n');
    expect(
      WindowShots.fromEnvironment(env).folder,
      '${home.path}/Pictures/Maprisma',
    );
    dirs.writeAsStringSync('XDG_PICTURES_DIR="relative"\n');
    expect(
      WindowShots.fromEnvironment(env).folder,
      '${home.path}/Pictures/Maprisma',
    );
    // A link in its place is not followed.
    File(
      '${home.path}/other',
    ).writeAsStringSync('XDG_PICTURES_DIR="/elsewhere"\n');
    dirs.deleteSync();
    Link(dirs.path).createSync('${home.path}/other');
    expect(
      WindowShots.fromEnvironment(env).folder,
      '${home.path}/Pictures/Maprisma',
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
