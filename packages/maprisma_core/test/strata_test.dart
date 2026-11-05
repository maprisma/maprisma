// Review 064: Strata's rules in the Dart core (provider_strata twins).
import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/provider_ops.dart' show portOf;
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/provider_watch.dart' show watchConfigText;
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/strata.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late StrataFacts strata;
  setUp(() {
    home = Directory.systemTemp.createTempSync('strata-test-');
    strata = StrataFacts(
      ScanFiles(
        AppIdentity(
          environment: {'HOME': home.path, 'PATH': '${home.path}/nothing'},
        ),
      ),
    );
  });
  tearDown(() => home.deleteSync(recursive: true));

  test(
    '#1: an oversized, signed or non-ASCII --port never throws; the config wins',
    () {
      final config = File('${home.path}/run.json')
        ..writeAsStringSync(jsonEncode({'port': 8123}));
      final server = [
        '${home.path}/.local/share/strata/terminal/0.1.57/python/bin/python3.12',
        '-m',
        'serve.server',
        '--config',
        config.path,
      ];
      for (final odd in [
        '9' * 5000,
        '99999999999999999999',
        '-8080',
        '８０８０',
        '²',
        '0',
        '65536',
        '1e3',
        ' 80',
      ]) {
        expect(
          strata.serverPort([...server, '--port', odd]),
          8123,
          reason: odd,
        );
        expect(
          strata.serverPort([...server, '--port=$odd']),
          8123,
          reason: odd,
        );
      }
      expect(
        strata.serverPort([...server, '--port', 'x', '--port', '9001']),
        9001,
      );
    },
  );

  test(
    '#1, the class: port text never fails a scan, the watcher config or an address',
    () {
      for (final (text, port) in [
        ('8080', 8080),
        ('65535', 65535),
        ('1', 1),
        ('²', 0),
        ('８０', 0),
        ('-1', 0),
        ('+80', 0),
        (' 80', 0),
        ('0', 0),
        ('65536', 0),
        ('9' * 5000, 0),
        ('', 0),
      ]) {
        expect(portNumber(text), port, reason: text);
      }
      for (final address in [
        '127.0.0.1:²',
        '127.0.0.1:${'9' * 30}',
        '127.0.0.1:-1',
        'nothing',
      ]) {
        final rt = RuntimeRecord('koboldcpp', 'KoboldCpp')
          ..installed = true
          ..service = 'koboldcpp'
          ..agents = ['pi']
          ..activeAgents = ['pi']
          ..address = address;
        expect(portOf(rt), 0, reason: address);
        expect(
          watchConfigText([rt], {}),
          contains('"port": 0'),
          reason: address,
        );
      }
    },
  );

  test(
    '#2: its server and engine only inside its own folders, as real paths',
    () {
      final data = '${home.path}/.local/share/strata';
      final python = '$data/terminal/0.1.57/python/bin/python3.12';
      final binary = '$data/components/engine/0.1.57-linux-x86_64-cuda/strata';
      final elsewhere =
          '${home.path}/tmp/strata/terminal/0.1.57/python/bin/python3.12';
      for (final path in [python, binary, elsewhere]) {
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync('');
      }
      final insideLink = '${home.path}/link-python';
      Link(insideLink).createSync(python);
      final outsideLink = '$data/terminal/0.1.57/python/bin/evil';
      Link(outsideLink).createSync(elsewhere);
      const server = ['-m', 'serve.server', '--config', '/x'];
      expect(strata.owns(python), isTrue);
      expect(strata.owns(binary), isTrue);
      expect(strata.owns(insideLink), isTrue);
      expect(strata.isServer([python, ...server]), isTrue);
      for (final exe in [
        elsewhere,
        outsideLink,
        '/usr/bin/strata',
        'relative/strata/terminal/x',
        '$data/terminal/../../elsewhere/strata/terminal/x',
        '$data/terminal/missing',
      ]) {
        expect(strata.owns(exe), isFalse, reason: exe);
        expect(strata.isServer([exe, ...server]), isFalse, reason: exe);
      }
      expect(strata.isServer([binary, ...server]), isFalse);
    },
  );
}
