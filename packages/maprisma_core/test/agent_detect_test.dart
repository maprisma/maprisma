import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_catalog.dart';
import 'package:maprisma_core/src/desktop.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;
  late String system;

  void program(String folder, String name, [String text = '']) {
    final file = File(p.join(folder, name))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
    Process.runSync('chmod', ['+x', file.path]);
  }

  (bool, String, String) detect(String path) {
    final identity = AppIdentity(
      environment: {'HOME': home.path, 'PATH': path},
    );
    return AgentCatalog(
      ScanFiles(identity),
      GenericDesktop(identity.environment),
    ).detect('claude', null);
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-detect-');
    system = p.join(home.path, 'usr/bin');
    Directory(system).createSync(recursive: true);
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('an agent of a distribution package is found on PATH', () {
    expect(detect(system), (false, '', ''));
    program(system, 'claude');
    expect(detect(system), (true, '', 'system'));
  });

  test('mise shims and wrappers are no installs', () {
    final mise = p.join(home.path, '.local/share/mise');
    final shims = p.join(mise, 'shims');
    final wrappers = p.join(mise, 'command-wrappers/bin');
    program(shims, 'claude');
    program(wrappers, 'claude');
    expect(detect('$shims:$wrappers:$system'), (false, '', ''));
  });

  test('an agent with an own installer is also found in mise', () {
    final version = Directory(
      p.join(home.path, '.local/share/mise/installs/antigravity-cli/1.4.11'),
    )..createSync(recursive: true);
    Link(p.join(version.parent.path, 'latest')).createSync('./1.4.11');
    final identity = AppIdentity(
      environment: {'HOME': home.path, 'PATH': system},
    );
    final adapter = Adapter({
      'command': 'agy',
      'name': 'Antigravity CLI',
      'installer': 'agy',
      'spec': 'antigravity-cli',
    });
    expect(
      AgentCatalog(
        ScanFiles(identity),
        GenericDesktop(identity.environment),
        adapters: [adapter],
      ).detect('agy', adapter),
      (true, '1.4.11', 'mise'),
    );
  });

  test('xdg-terminal-exec without a terminal entry is passed over', () {
    program(system, 'xdg-terminal-exec', '#!/bin/sh\nexit 1\n');
    program(system, 'cosmic-term');
    expect(GenericDesktop({'PATH': system}).terminal(), [
      p.join(system, 'cosmic-term'),
      '--',
    ]);
  });

  test('a working xdg-terminal-exec comes first', () {
    program(system, 'xdg-terminal-exec', '#!/bin/sh\nexit 0\n');
    program(system, 'cosmic-term');
    expect(GenericDesktop({'PATH': system}).terminal(), [
      p.join(system, 'xdg-terminal-exec'),
    ]);
  });
}
