import 'dart:io';

import 'package:maprisma_core/src/agent_details.dart';
import 'package:maprisma_core/src/desktop.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/service_i18n.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

/// Omarchy's usage records (desktop_omarchy / agent_details): stale when
/// Omarchy collects for the agent and the record is missing, older than ten
/// minutes or older than the agent's sign-in; refreshed through
/// omarchy-agent-usage-update; nothing for agents Omarchy does not collect.
void main() {
  late Directory root;
  late Map<String, String> env;
  late DetailReaders details;
  setUp(() {
    root = Directory.systemTemp.createTempSync('usage-refresh');
    final omarchy = Directory('${root.path}/omarchy/bin')
      ..createSync(recursive: true);
    File('${omarchy.path}/omarchy-agent-usage-claude').writeAsStringSync('');
    final bin = Directory('${root.path}/bin')..createSync();
    File('${bin.path}/omarchy-agent-usage-update').writeAsStringSync(
      '#!/bin/sh\n'
      'mkdir -p "\$XDG_STATE_HOME/omarchy/agents/usage"\n'
      'echo "{}" > "\$XDG_STATE_HOME/omarchy/agents/usage/\$1.json"\n',
    );
    Process.runSync('chmod', ['755', '${bin.path}/omarchy-agent-usage-update']);
    env = {
      'HOME': root.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'OMARCHY_PATH': '${root.path}/omarchy',
      'XDG_STATE_HOME': '${root.path}/state',
      'XDG_CONFIG_HOME': '${root.path}/config',
    };
    final identity = AppIdentity(environment: env);
    details = DetailReaders(
      ScanFiles(identity),
      OmarchyDesktop(identity, Posix()),
      ServiceI18n(identity, SettingsStore(identity)),
    );
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('stale, refreshed, fresh, and stale again after a sign-in', () async {
    expect(usageCollectorExists('claude', env), isTrue);
    expect(usageCollectorExists('not-collected', env), isFalse);
    expect(usageCollectorExists('../x', env), isFalse);
    expect(
      details.usageIsStale('claude', ['.claude/.credentials.json']),
      isTrue,
    );
    expect(await refreshUsage('claude', env), isTrue);
    final record = File('${root.path}/state/omarchy/agents/usage/claude.json');
    expect(record.existsSync(), isTrue);
    expect(
      details.usageIsStale('claude', ['.claude/.credentials.json']),
      isFalse,
    );
    expect(
      details.usageIsStale(
        'claude',
        const [],
        now: DateTime.now().add(const Duration(minutes: 11)),
      ),
      isTrue,
    );
    final credentials = File('${root.path}/.claude/.credentials.json')
      ..createSync(recursive: true);
    credentials.setLastModifiedSync(
      DateTime.now().add(const Duration(seconds: 5)),
    ); // signed in after the record was written
    expect(
      details.usageIsStale('claude', ['.claude/.credentials.json']),
      isTrue,
    );
  });

  test('not collected or not Omarchy: never stale, never asked', () async {
    expect(details.usageIsStale('no-such-agent-x', const []), isFalse);
    expect(await refreshUsage('no-such-agent-x', env), isFalse);
    final identity = AppIdentity(environment: env);
    final generic = DetailReaders(
      ScanFiles(identity),
      GenericDesktop(env),
      ServiceI18n(identity, SettingsStore(identity)),
    );
    expect(generic.usageIsStale('claude', const []), isFalse);
  });
}
