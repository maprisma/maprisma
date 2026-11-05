import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_details.dart';
import 'package:maprisma_core/src/usage_rpc.dart';
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

  test('not collected: never stale, never asked', () async {
    expect(details.usageIsStale('no-such-agent-x', const []), isFalse);
    expect(await refreshUsage('no-such-agent-x', env), isFalse);
  });

  test('another desktop runs a collector found on PATH itself', () async {
    final bin = Directory('${root.path}/local-bin')..createSync();
    void collector(String name, String body) {
      File(
        '${bin.path}/omarchy-agent-usage-$name',
      ).writeAsStringSync('#!/bin/sh\n$body\n');
      Process.runSync('chmod', [
        '755',
        '${bin.path}/omarchy-agent-usage-$name',
      ]);
    }

    collector(
      'codex',
      'echo \'{"tierLabel": "Plus", "limits": [{"label": "Weekly", '
          '"percent": 0.25}]}\'',
    );
    collector('grok', 'echo not json');
    collector('gemini', 'exit 3');
    final generic = {
      'HOME': root.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'XDG_STATE_HOME': '${root.path}/state',
      'XDG_CONFIG_HOME': '${root.path}/config',
    };
    final identity = AppIdentity(environment: generic);
    final other = DetailReaders(
      ScanFiles(identity),
      GenericDesktop(generic),
      ServiceI18n(identity, SettingsStore(identity)),
    );
    expect(usageCollectorExists('codex', generic), isTrue);
    expect(other.usageIsStale('codex', const []), isTrue);
    expect(await refreshUsage('codex', generic), isTrue);
    expect(other.usageIsStale('codex', const []), isFalse);
    expect(other.usageRecord('codex')['tierLabel'], 'Plus');
    // What is not one JSON object, or a failed run, writes nothing.
    expect(await refreshUsage('grok', generic), isFalse);
    expect(await refreshUsage('gemini', generic), isFalse);
    for (final name in ['grok', 'gemini']) {
      expect(
        File('${root.path}/state/omarchy/agents/usage/$name.json').existsSync(),
        isFalse,
      );
    }
    // No collector: the generic desktop keeps no record and asks nobody.
    expect(other.usageIsStale('copilot', const []), isFalse);
    expect(other.usageRecord('copilot'), isEmpty);
  });

  test(
    'no collector: Codex is asked itself over its app-server, then killed',
    () async {
      final bin = Directory('${root.path}/codex-bin')..createSync();
      // A fake `codex … app-server`: the handshake, a notification before the
      // answer, then it would stay up for a minute.
      File('${bin.path}/codex').writeAsStringSync(r"""#!/bin/sh
[ "$*" = "-s read-only -a on-request app-server" ] || exit 9
read -r line
case "$line" in *'"initialize"'*) ;; *) exit 8;; esac
printf '{"id":1,"result":{}}\n'
read -r line
read -r line
case "$line" in *account/rateLimits/read*) ;; *) exit 7;; esac
printf '{"method":"note","params":{}}\n{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":4102444800},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":4102531200}}}}\n'
echo $$ > "$HOME/app-server.pid"
sleep 60
""");
      Process.runSync('chmod', ['755', '${bin.path}/codex']);
      final generic = {
        'HOME': root.path,
        'PATH': '${bin.path}:/usr/bin:/bin',
        'XDG_STATE_HOME': '${root.path}/state',
        'XDG_CONFIG_HOME': '${root.path}/config',
      };
      final identity = AppIdentity(environment: generic);
      final other = DetailReaders(
        ScanFiles(identity),
        GenericDesktop(generic),
        ServiceI18n(identity, SettingsStore(identity)),
      );
      final codex = builtinAdapters().firstWhere((a) => a.command == 'codex');
      // Not signed in (no access file): never asked.
      expect(other.planLimitsRpc(codex), isNull);
      File('${root.path}/.codex/auth.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('not read');
      final native = other.planLimitsRpc(codex)!;
      expect(native.$1, 'codex-app-server');
      expect(native.$2, [
        'codex',
        '-s',
        'read-only',
        '-a',
        'on-request',
        'app-server',
      ]);
      expect(
        other.usageIsStale('codex', const []),
        isFalse,
      ); // not native: as before
      expect(other.usageIsStale('codex', const [], native: true), isTrue);
      final started = DateTime.now();
      expect(
        await refreshUsage('codex', generic, rpc: native.$1, argv: native.$2),
        isTrue,
      );
      expect(DateTime.now().difference(started).inSeconds, lessThan(15));
      final pid = File('${root.path}/app-server.pid').readAsStringSync().trim();
      expect(
        Directory('/proc/$pid').existsSync(),
        isFalse,
      ); // killed afterwards
      expect(
        File('${root.path}/state/maprisma/usage/codex.json').existsSync(),
        isTrue,
      );
      expect(other.usageIsStale('codex', const [], native: true), isFalse);
      final record = other.usageRecord('codex');
      expect(record['tierLabel'], 'plus');
      expect(record['limitsStale'], isFalse);
      expect(record['limits'], [
        {
          'label': '5h window',
          'percent': 0.25,
          'resetsAt': '2100-01-01T00:00:00.000Z',
        },
        {
          'label': 'Weekly (7-day)',
          'percent': 0.6,
          'resetsAt': '2100-01-02T00:00:00.000Z',
        },
      ]);
      final info = other.read(codex);
      expect(info.plan, 'Plus');
      expect(info.limits.map((l) => l['percent']), [0.25, 0.6]);
      // With Omarchy's collector on PATH, that stays the first source.
      File('${bin.path}/omarchy-agent-usage-codex').writeAsStringSync('');
      Process.runSync('chmod', [
        '755',
        '${bin.path}/omarchy-agent-usage-codex',
      ]);
      expect(other.planLimitsRpc(codex), isNull);
    },
  );

  test('an app-server that does not answer is killed after its time', () async {
    final bin = Directory('${root.path}/slow-bin')..createSync();
    File(
      '${bin.path}/codex',
    ).writeAsStringSync('#!/bin/sh\necho \$\$ > "\$HOME/slow.pid"\nsleep 60\n');
    Process.runSync('chmod', ['755', '${bin.path}/codex']);
    final generic = {
      'HOME': root.path,
      'PATH': '${bin.path}:/usr/bin:/bin',
      'XDG_STATE_HOME': '${root.path}/state',
    };
    final started = DateTime.now();
    expect(
      await askPlanLimits(
        'codex-app-server',
        const ['codex', 'app-server'],
        generic,
        answer: const Duration(seconds: 1),
      ),
      isNull,
    );
    expect(DateTime.now().difference(started).inSeconds, lessThan(6));
    final pid = File('${root.path}/slow.pid').readAsStringSync().trim();
    expect(Directory('/proc/$pid').existsSync(), isFalse);
    expect(await refreshUsage('codex', generic), isFalse); // no rpc: not asked
    expect(
      await askPlanLimits('something-else', const ['codex'], generic),
      isNull,
    );
  });
}
