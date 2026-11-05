import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_badges.dart';
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

  test('limits whose record names no time are as old as its file', () {
    final record = File('${root.path}/state/omarchy/agents/usage/claude.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '{"limits": [{"label": "Week", "percent": 0.4}], "tierLabel": "Pro"}',
      );
    final written = DateTime.utc(2026, 11, 5, 9, 30, 12);
    record.setLastModifiedSync(written);
    final claude = builtinAdapters().firstWhere((a) => a.command == 'claude');
    final limits = details.read(claude).limits;
    expect(limits.single['measured_at'], AgentInfo.iso(written));
    final later = written.add(const Duration(hours: 2));
    expect(currentLimits(limits, later), isEmpty); // no reset, too old
    expect(battery(limits, (0.75, 0.9), later), isNull);
    expect(currentLimits(limits, written), limits); // fresh at first
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
      expect(native.$3, '${bin.path}/codex'); // the installed program
      expect(
        other.usageIsStale('codex', const []),
        isFalse,
      ); // not native: as before
      expect(other.usageIsStale('codex', const [], native: true), isTrue);
      final started = DateTime.now();
      expect(
        await refreshUsage(
          'codex',
          generic,
          rpc: native.$1,
          argv: native.$2,
          program: native.$3,
          home: other.usageHome(codex),
        ),
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
      // Signed out: the record is the old account's, no longer this PC's.
      File('${root.path}/.codex/auth.json').deleteSync();
      expect(other.read(codex).limits, isEmpty);
      expect(other.read(codex).plan, '');
      expect(other.usageRecord('codex', codex), isEmpty);
      expect(other.planLimitsRpc(codex), isNull);
      File('${root.path}/.codex/auth.json').writeAsStringSync('not read');
      expect(other.read(codex).limits, hasLength(2)); // signed in again
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
        program: '${bin.path}/codex',
        answer: const Duration(seconds: 1),
      ),
      isNull,
    );
    expect(DateTime.now().difference(started).inSeconds, lessThan(6));
    final pid = File('${root.path}/slow.pid').readAsStringSync().trim();
    expect(Directory('/proc/$pid').existsSync(), isFalse);
    expect(await refreshUsage('codex', generic), isFalse); // no rpc: not asked
    expect(
      await askPlanLimits(
        'something-else',
        const ['codex'],
        generic,
        program: '${bin.path}/codex',
      ),
      isNull,
    );
    // No program found: never the first `codex` on PATH.
    File('${root.path}/slow.pid').deleteSync();
    expect(
      await askPlanLimits(
        'codex-app-server',
        const ['codex', 'app-server'],
        generic,
        program: null,
      ),
      isNull,
    );
    expect(File('${root.path}/slow.pid').existsSync(), isFalse);
  });

  group('the program asked for plan limits', () {
    late Map<String, String> generic;
    late DetailReaders other;
    late Adapter codex;
    late String ran;
    // A program that leaves a mark when it is started: none may be.
    String program(String path, [String body = '']) {
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n$body\ntouch "$ran"\n');
      Process.runSync('chmod', ['755', path]);
      return path;
    }

    setUp(() {
      ran = '${root.path}/started';
      generic = {
        'HOME': root.path,
        'PATH': '${root.path}/.local/bin:${root.path}/.local/share/mise/shims',
        'XDG_STATE_HOME': '${root.path}/state',
        'XDG_CONFIG_HOME': '${root.path}/config',
      };
      final identity = AppIdentity(environment: generic);
      other = DetailReaders(
        ScanFiles(identity),
        GenericDesktop(generic),
        ServiceI18n(identity, SettingsStore(identity)),
      );
      codex = builtinAdapters().firstWhere((a) => a.command == 'codex');
      File('${root.path}/.codex/auth.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('not read');
    });

    test('is never a launcher that installs or updates it', () {
      // Omarchy's lazy launcher first on PATH, then mise's shim.
      program(
        '${root.path}/.local/bin/codex',
        'export MISE_MINIMUM_RELEASE_AGE=0\n'
            'mise use -g --quiet "codex" || exit 1\n'
            'exec mise x "codex" -- "codex" "\$@"',
      );
      program('${root.path}/.local/share/mise/shims/codex');
      expect(other.planLimitsRpc(codex), isNull); // nothing real: not asked
      // A link to mise itself is a shim too.
      final mise = program('${root.path}/tools/mise');
      File('${root.path}/.local/bin/codex').deleteSync();
      Link('${root.path}/.local/bin/codex').createSync(mise);
      expect(other.planLimitsRpc(codex), isNull);
      // The version mise installed is the real program.
      final installed = program(
        '${root.path}/.local/share/mise/installs/codex/0.50.0/bin/codex',
      );
      expect(other.planLimitsRpc(codex)?.$3, installed);
      // So is an own install on PATH, before mise's.
      Link('${root.path}/.local/bin/codex').deleteSync();
      final own = program('${root.path}/.local/bin/codex');
      expect(other.planLimitsRpc(codex)?.$3, own);
      expect(File(ran).existsSync(), isFalse); // nothing was started
    });

    test('a keyring store or a moved CODEX_HOME is a sign-in too', () {
      program('${root.path}/.local/bin/codex');
      File('${root.path}/.codex/auth.json').deleteSync();
      expect(other.planLimitsRpc(codex), isNull); // the file store, empty
      final config = File('${root.path}/.codex/config.toml')
        ..writeAsStringSync('cli_auth_credentials_store = "file"\n');
      expect(other.planLimitsRpc(codex), isNull);
      config.writeAsStringSync('cli_auth_credentials_store = "keyring"\n');
      expect(other.planLimitsRpc(codex), isNotNull); // only Codex can tell
      config.deleteSync();
      // CODEX_HOME moves the sign-in file and the store setting.
      final moved = Directory('${root.path}/codex-home')..createSync();
      generic['CODEX_HOME'] = moved.path;
      final identity = AppIdentity(environment: generic);
      final relocated = DetailReaders(
        ScanFiles(identity),
        GenericDesktop(generic),
        ServiceI18n(identity, SettingsStore(identity)),
      );
      File('${root.path}/.codex/auth.json').writeAsStringSync('not read');
      expect(relocated.planLimitsRpc(codex), isNull); // ~/.codex is not it
      expect(relocated.accessPaths(codex), ['${moved.path}/auth.json']);
      File(
        '${moved.path}/config.toml',
      ).writeAsStringSync('cli_auth_credentials_store = "auto"\n');
      expect(relocated.planLimitsRpc(codex), isNotNull);
      File('${moved.path}/config.toml').deleteSync();
      final auth = File('${moved.path}/auth.json')..writeAsStringSync('x');
      expect(relocated.planLimitsRpc(codex), isNotNull);
      // A new sign-in there makes the record stale.
      File(nativeUsagePath('codex', generic))
        ..createSync(recursive: true)
        ..writeAsStringSync('{}');
      auth.setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
      expect(
        relocated.usageIsStale(
          'codex',
          relocated.accessPaths(codex),
          native: true,
        ),
        isTrue,
      );
    });
  });

  group('round 3: whose sign-in, which home, which record', () {
    late Map<String, String> generic;
    late Adapter codex;
    late Directory bin;
    DetailReaders readers(Map<String, String> env, {bool omarchy = false}) {
      final identity = AppIdentity(environment: env);
      return DetailReaders(
        ScanFiles(identity),
        omarchy ? OmarchyDesktop(identity, Posix()) : GenericDesktop(env),
        ServiceI18n(identity, SettingsStore(identity)),
      );
    }

    // A fake `codex app-server` that answers account/rateLimits/read with
    // [reply] (a JSON-RPC body after "id":2), or says nothing and ends.
    void fake(String? reply) {
      File('${bin.path}/codex').writeAsStringSync(
        reply == null
            ? '#!/bin/sh\nexit 0\n'
            : '#!/bin/sh\n'
                  'read -r line\nprintf \'{"id":1,"result":{}}\\n\'\n'
                  'read -r line\nread -r line\n'
                  "printf '%s\\n' '{\"id\":2,$reply}'\n",
      );
      Process.runSync('chmod', ['755', '${bin.path}/codex']);
    }

    const limits =
        '"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":4102444800}}}';
    const authFailure = '"error":{"code":-32600,"message":"Not authenticated"}';

    Future<bool> ask(DetailReaders d, Map<String, String> env) {
      final native = d.planLimitsRpc(codex)!;
      return refreshUsage(
        'codex',
        env,
        rpc: native.$1,
        argv: native.$2,
        program: native.$3,
        home: d.usageHome(codex),
      );
    }

    setUp(() {
      bin = Directory('${root.path}/codex-bin')..createSync();
      generic = {
        'HOME': root.path,
        'PATH': '${bin.path}:/usr/bin:/bin',
        'XDG_STATE_HOME': '${root.path}/state',
        'XDG_CONFIG_HOME': '${root.path}/config',
      };
      codex = builtinAdapters().firstWhere((a) => a.command == 'codex');
    });

    test(
      '#10: a keyring store may be asked; its answer says signed in',
      () async {
        final d = readers(generic);
        File('${root.path}/.codex/config.toml')
          ..createSync(recursive: true)
          ..writeAsStringSync('cli_auth_credentials_store = "keyring"\n');
        // Never asked: may be asked, and as before counts as signed in.
        expect(d.limitsProbeable(codex), isTrue);
        expect(d.programAnswer(codex), isNull);
        expect(d.limitsSignedIn(codex), isTrue);
        // Codex says nobody is signed in to its keyring: not signed in, but it
        // is asked again (a new sign-in is found so).
        fake(authFailure);
        expect(await ask(d, generic), isTrue);
        expect(d.programAnswer(codex), isFalse);
        expect(d.limitsSignedIn(codex), isFalse);
        expect(d.usageRecord('codex', codex), isEmpty);
        expect(d.planLimitsRpc(codex), isNotNull);
        // No answer (it ends at once): unknown again, as before.
        fake(null);
        expect(await ask(d, generic), isFalse);
        expect(d.programAnswer(codex), isNull);
        expect(d.limitsSignedIn(codex), isTrue);
        // Signed in again: its limits came.
        fake(limits);
        expect(await ask(d, generic), isTrue);
        expect(d.programAnswer(codex), isTrue);
        expect(d.read(codex).limits, hasLength(1));
        // An auth failure after that hides the limits.
        fake(authFailure);
        expect(await ask(d, generic), isTrue);
        expect(d.read(codex).limits, isEmpty);
        expect(d.read(codex).plan, '');
        // Without the keyring setting (the file store, no auth.json) its old
        // answer does not count: not signed in, never asked.
        File('${root.path}/.codex/config.toml').deleteSync();
        expect(d.limitsSignedIn(codex), isFalse);
        expect(d.planLimitsRpc(codex), isNull);
      },
    );

    test(
      '#12: another CODEX_HOME never shows the first home\'s limits',
      () async {
        final first = Directory('${root.path}/home-a')..createSync();
        final second = Directory('${root.path}/home-b')..createSync();
        final auth = File('${second.path}/auth.json')..writeAsStringSync('x');
        auth.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 1)),
        );
        File('${first.path}/auth.json').writeAsStringSync('x');
        final a = {...generic, 'CODEX_HOME': first.path};
        final b = {...generic, 'CODEX_HOME': second.path};
        final da = readers(a), db = readers(b);
        expect(da.usageHome(codex), isNot(db.usageHome(codex)));
        expect(readers(generic).usageHome(codex), isNot(da.usageHome(codex)));
        fake(limits);
        expect(await ask(da, a), isTrue);
        expect(da.read(codex).limits, hasLength(1));
        expect(
          da.usageIsStale(
            'codex',
            da.accessPaths(codex),
            native: true,
            adapter: codex,
          ),
          isFalse,
        );
        // The same record file, but the other home: no limits, and due at once
        // even though that home's sign-in predates the record.
        expect(db.read(codex).limits, isEmpty);
        expect(db.usageRecord('codex', codex), isEmpty);
        expect(
          db.usageIsStale(
            'codex',
            db.accessPaths(codex),
            native: true,
            adapter: codex,
          ),
          isTrue,
        );
        // A record without a home (written before) is no home's.
        File(nativeUsagePath('codex', a)).writeAsStringSync(
          '{"limits":[{"label":"x","percent":0.5}],"limitsFetchedAt":${DateTime.now().millisecondsSinceEpoch}}',
        );
        expect(da.read(codex).limits, isEmpty);
      },
    );

    test(
      '#14: on Omarchy without the collector, the newer record is read',
      () async {
        final omarchyEnv = {...generic, 'OMARCHY_PATH': '${root.path}/omarchy'};
        final d = readers(omarchyEnv, omarchy: true);
        File('${root.path}/.codex/auth.json')
          ..createSync(recursive: true)
          ..writeAsStringSync('not read');
        final old = File('${root.path}/state/omarchy/agents/usage/codex.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '{"limits":[{"label":"Old","percent":0.9}],"tierLabel":"pro",'
            '"limitsFetchedAt":${DateTime.now().subtract(const Duration(hours: 3)).millisecondsSinceEpoch}}',
          );
        final native = nativeUsagePath('codex', omarchyEnv);
        expect(d.usagePath('codex', codex), old.path); // nothing else yet
        // Due: Maprisma's own record, the one the refresh writes, is missing.
        expect(
          d.usageIsStale(
            'codex',
            d.accessPaths(codex),
            native: true,
            adapter: codex,
          ),
          isTrue,
        );
        fake(limits);
        expect(await ask(d, omarchyEnv), isTrue);
        expect(d.usagePath('codex', codex), native);
        expect(d.read(codex).limits.single['percent'], 0.25);
        expect(d.read(codex).plan, 'Plus');
        expect(
          d.usageIsStale(
            'codex',
            d.accessPaths(codex),
            native: true,
            adapter: codex,
          ),
          isFalse,
        );
        // Omarchy's newer than Maprisma's: Omarchy's.
        old.writeAsStringSync(
          '{"limits":[{"label":"New","percent":0.1}],'
          '"limitsFetchedAt":${DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch}}',
        );
        expect(d.usagePath('codex', codex), old.path);
        // With its collector, Omarchy's record as before.
        Directory('${root.path}/omarchy/bin').createSync(recursive: true);
        File(
          '${root.path}/omarchy/bin/omarchy-agent-usage-codex',
        ).writeAsStringSync('');
        old.writeAsStringSync('{"limits":[]}');
        old.setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 1)),
        );
        expect(d.usagePath('codex', codex), old.path);
      },
    );
  });
}
