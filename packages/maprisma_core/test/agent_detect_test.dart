import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/addons.dart';
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

  test('OpenClaw and Hermes outside their packages count when proven', () {
    // npm, upstream's installers, pipx or a wrapper of the user's count when
    // the program is proven the agent's (install_marks); another program by
    // the name, or Omarchy's old stub that runs mise, does not.
    final bin = p.join(home.path, '.local/bin');
    Directory(bin).createSync(recursive: true);
    String made(String path, [String text = '#!/bin/sh\n']) {
      program(p.dirname(path), p.basename(path), text);
      return path;
    }

    (bool, String, String) of(String command) {
      final identity = AppIdentity(
        environment: {'HOME': home.path, 'PATH': system},
      );
      final catalog = AgentCatalog(
        ScanFiles(identity),
        GenericDesktop(identity.environment),
      );
      return catalog.detect(command, catalog.adapter(command));
    }

    made(p.join(system, 'openclaw')); // someone else's openclaw
    made(p.join(system, 'hermes')); // the Hermes JavaScript engine
    expect(of('openclaw'), (false, '', ''));
    expect(of('hermes'), (false, '', ''));
    File(p.join(system, 'openclaw')).deleteSync(); // npm -g: a link into it
    Link(p.join(system, 'openclaw')).createSync(
      made(p.join(home.path, 'npm/lib/node_modules/openclaw/openclaw.mjs')),
    );
    expect(of('openclaw'), (true, '', 'system'));
    Link(p.join(system, 'openclaw')).deleteSync(); // upstream's install-cli.sh
    Link(
      p.join(bin, 'openclaw'),
    ).createSync(made(p.join(home.path, '.openclaw/bin/openclaw')));
    expect(of('openclaw'), (true, '', 'own'));
    made(
      p.join(bin, 'hermes'),
      '#!/bin/bash\n\n# Written by omarchy-install-hermes-cli.\n\n'
      'if ! [[ -d "\$(mise where \'pipx:hermes-agent[extras=all]\')'
      '/hermes-agent/lib" ]]; then\n'
      "  mise use -g --quiet --force 'pipx:hermes-agent[extras=all]' || exit 1\n"
      'fi\n\n'
      "exec mise x 'pipx:hermes-agent[extras=all]' -- hermes \"\$@\"\n",
    );
    expect(of('hermes'), (false, '', ''));
    made(
      p.join(bin, 'hermes'),
      '#!/bin/bash\nexec "${home.path}/.hermes/hermes-agent/venv/bin/hermes" '
      '"\$@"\n',
    );
    expect(of('hermes'), (true, '', 'own')); // upstream's installer
    File(p.join(bin, 'hermes')).deleteSync(); // pipx
    Link(p.join(bin, 'hermes')).createSync(
      made(
        p.join(home.path, '.local/share/pipx/venvs/hermes-agent/bin/hermes'),
      ),
    );
    expect(of('hermes'), (true, '', 'own'));
  });

  test('an add-on signed before install_marks gets the app\'s', () {
    final own = builtinAdapters().firstWhere((a) => a.command == 'openclaw');
    final merged = withNewerFacts({
      'command': 'openclaw',
      'name': 'OpenClaw',
      'package': 'openclaw',
      'package_only': true,
    }, own.facts);
    expect(merged['install_marks'], own.facts['install_marks']);
    expect(merged['install_marks'], isNotEmpty);
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
