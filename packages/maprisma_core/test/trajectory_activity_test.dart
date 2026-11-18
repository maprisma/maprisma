import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/live_session_activity.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/pty_sessions.dart' show processIdentity;
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/sqlite_numbers.dart';
import 'package:maprisma_core/src/trajectory_activity.dart';
import 'package:test/test.dart';

List<int> _varint(int value) =>
    value < 128 ? [value] : [(value & 127) | 128, ..._varint(value >> 7)];

List<int> _field(int tag, List<int> data) => [
  ..._varint(tag * 8 + 2),
  ..._varint(data.length),
  ...data,
];

String _blob(List<int> data) =>
    "X'${data.map((n) => n.toRadixString(16).padLeft(2, '0')).join()}'";

void main() {
  late Directory home;
  late SqliteNumbers sqlite;
  late String path;
  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-activity-');
    sqlite = SqliteNumbers(
      ScanFiles(AppIdentity(environment: {'HOME': home.path})),
    );
    path = '${home.path}/session.db';
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('reads the latest request, answer, tool and edited path', () {
    final request = _blob(_field(19, _field(2, utf8.encode('Latest request'))));
    final answer = _blob(_field(20, _field(1, utf8.encode('Answer'))));
    final tool = _blob([
      ..._field(5, _field(4, _field(2, utf8.encode('write_file')))),
      ..._field(140, _field(1, _field(2, utf8.encode('/work/file.txt')))),
    ]);
    final result = Process.runSync('sqlite3', [
      path,
      'CREATE TABLE steps(idx INTEGER PRIMARY KEY, step_type INTEGER, '
          'status INTEGER, step_format INTEGER, step_payload BLOB);'
          'INSERT INTO steps VALUES (0,14,3,1,X\'00\'), '
          '(1,14,3,0,$request), (2,132,3,0,$tool), (3,15,3,0,$answer);',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final before = File(path).readAsBytesSync();
    final activity = trajectoryActivity(sqlite, path, 'fixture');
    expect(activity['status'], 'available');
    expect(activity['request']['text'], 'Latest request');
    expect(activity['answers'].single['text'], 'Answer');
    expect(activity['tool_calls'].single['name'], 'write_file');
    expect(activity['edited_files'].single['path'], '/work/file.txt');
    expect(File(path).readAsBytesSync(), before);
    expect(File('$path-wal').existsSync(), isFalse);
  });

  test('live route binds the open database to this process birth', () async {
    final dir = Directory('${home.path}/sessions')..createSync();
    final database = '${dir.path}/d476f968-2f99-412f-9621-c79c8c86376d.db';
    final request = _blob(_field(19, _field(2, utf8.encode('Live request'))));
    final sql = Process.runSync('sqlite3', [
      database,
      'CREATE TABLE steps(idx INTEGER PRIMARY KEY, step_type INTEGER, '
          'status INTEGER, step_format INTEGER, step_payload BLOB);'
          'INSERT INTO steps VALUES (0,14,3,0,$request);',
    ]);
    expect(sql.exitCode, 0, reason: sql.stderr.toString());
    final agent = '${home.path}/fixture-agent';
    Link(agent).createSync('/usr/bin/sleep');
    final process = await Process.start('/usr/bin/bash', [
      '-c',
      r'exec 3<"$1"; exec "$2" 30',
      'fixture',
      database,
      agent,
    ]);
    try {
      final scans = ProviderScans(sqlite.files);
      final instance = '${process.pid}:${processIdentity(process.pid)!.$3}';
      final facts = {
        'activity_reader': 'trajectory-sqlite',
        'activity_dir': '~/sessions',
      };
      // Process.start may return before the shell has exec'd the fixture.
      Map<String, dynamic> activity = {};
      for (var tries = 0; tries < 40; tries++) {
        activity = liveSessionActivity(scans, 'fixture-agent', instance, facts);
        if (activity['request'] != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(activity['request'], containsPair('text', 'Live request'));
      expect(
        liveSessionActivity(
          scans,
          'fixture-agent',
          '${process.pid}:0',
          facts,
        )['status'],
        'unavailable',
      );
      expect(
        liveSessionActivity(scans, 'other-agent', instance, facts)['status'],
        'unavailable',
      );
    } finally {
      process.kill();
      await process.exitCode;
    }
  });

  test('schema drift yields unavailable', () {
    final result = Process.runSync('sqlite3', [
      path,
      'CREATE TABLE steps(idx INTEGER PRIMARY KEY);',
    ]);
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      trajectoryActivity(sqlite, path, 'fixture')['status'],
      'unavailable',
    );
  });
}
