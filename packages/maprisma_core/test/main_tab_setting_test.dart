import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/inventory.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late CoreService core;
  setUp(() {
    home = Directory.systemTemp.createTempSync('maprisma-main-tab-');
    core = CoreService(
      environment: {
        'HOME': home.path,
        'XDG_CONFIG_HOME': '${home.path}/.config',
        'XDG_DATA_HOME': '${home.path}/.local/share',
        'XDG_CACHE_HOME': '${home.path}/.cache',
        'XDG_STATE_HOME': '${home.path}/.local/state',
        'PATH': Platform.environment['PATH'] ?? '/usr/bin',
      },
      migrate: false,
    );
  });
  tearDown(() {
    core.dispose();
    home.deleteSync(recursive: true);
  });

  test('main_tab is null until picked, then projects or map', () {
    expect(core.settings.load()['main_tab'], isNull);
    core.settings.update({
      'values': {'main_tab': 'projects'},
    });
    expect(core.settings.load()['main_tab'], 'projects');
    core.settings.update({
      'values': {'main_tab': 'map'},
    });
    expect(core.settings.load()['main_tab'], 'map');
    expect(
      () => core.settings.update({
        'values': {'main_tab': 'reports'},
      }),
      throwsA(anything),
    );
    expect(core.settings.load()['main_tab'], 'map');
  });

  test('main_tab through the routes, back to null too', () async {
    await core.dispatchAsync('settings.update', {
      'values': {'main_tab': 'projects'},
    });
    expect(
      (await core.dispatchAsync('settings.get', {}))['main_tab'],
      'projects',
    );
    await core.dispatchAsync('settings.update', {
      'values': {'main_tab': null},
    });
    expect((await core.dispatchAsync('settings.get', {}))['main_tab'], isNull);
  });

  test('every discovery route exists in routes.json', () {
    final routes =
        (jsonDecode(File('protocol/routes.json').readAsStringSync())
                as Map)['routes']
            as Map;
    for (final name in CoreService.discoveryRoutes) {
      expect(routes.containsKey(name), isTrue, reason: name);
    }
  });

  test(
    'the discovery generation grows after success, not on failure',
    () async {
      final before = core.discoveryGeneration;
      await expectLater(
        core.dispatchAsync('settings.update', {
          'values': {'main_tab': 'reports'},
        }),
        throwsA(anything),
      );
      expect(core.discoveryGeneration, before);
      await core.dispatchAsync('settings.update', {
        'values': {'main_tab': 'map'},
      });
      expect(core.discoveryGeneration, before + 1);
    },
  );

  test('a finished map scan grows the generation only when facts changed', () {
    final scan = core.reads.onInventory!;
    final before = core.discoveryGeneration;
    scan(InventorySnapshot(), const []);
    expect(core.discoveryGeneration, before + 1);
    scan(InventorySnapshot(), const []);
    expect(core.discoveryGeneration, before + 1);
    final changed = InventorySnapshot()
      ..runtimes.add(RuntimeRecord('ollama', 'Ollama')..installed = true);
    scan(changed, const []);
    expect(core.discoveryGeneration, before + 2);
    // Each single change of what a project's approval reads grows it,
    // measured against the same baseline every time.
    RuntimeRecord base() => RuntimeRecord('ollama', 'Ollama')
      ..installed = true
      ..agents = ['pi']
      ..bindings = ['pi=ollama'];
    for (final change in <void Function(RuntimeRecord)>[
      (r) => r.address = '127.0.0.1:11435',
      (r) => r.serverOff = true,
      (r) => r.agents = ['pi', 'opencode'],
      (r) => r.bindings = ['pi=ollama-b'],
      (r) => r.bindings = ['pi=ollama', 'pi=ollama-b'],
    ]) {
      scan(InventorySnapshot()..runtimes.add(base()), const []);
      final next = core.discoveryGeneration;
      final record = base();
      change(record);
      scan(InventorySnapshot()..runtimes.add(record), const []);
      expect(core.discoveryGeneration, next + 1);
      // The same scan again changes nothing.
      scan(InventorySnapshot()..runtimes.add(record), const []);
      expect(core.discoveryGeneration, next + 1);
    }
    // An agent merely working there does not count.
    scan(InventorySnapshot()..runtimes.add(base()), const []);
    final idle = core.discoveryGeneration;
    scan(
      InventorySnapshot()..runtimes.add(base()..activeAgents = ['pi']),
      const [],
    );
    expect(core.discoveryGeneration, idle);
  });
}
