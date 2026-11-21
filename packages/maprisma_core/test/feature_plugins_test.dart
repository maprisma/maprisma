import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/core_tasks.dart';
import 'package:maprisma_core/src/feature_plugins.dart';
import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late AppIdentity identity;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('maprisma-feature-test-');
    identity = AppIdentity(
      environment: {
        ...Platform.environment,
        'HOME': temporary.path,
        'XDG_DATA_HOME': temporary.path,
      },
    );
  });
  tearDown(() => temporary.deleteSync(recursive: true));
  List<String> fixture([
    String id = 'reports',
    String mode = '',
    String? launches,
  ]) => [
    Platform.resolvedExecutable,
    File('test/fixtures/feature_plugin_fixture.dart').absolute.path,
    id,
    if (mode.isNotEmpty || launches != null) mode.isEmpty ? '-' : mode,
    ?launches,
  ];

  /// Waits (bounded) until the late @shutdown confirmation was taken: it
  /// drops the feature's handles.
  Future<void> confirmed(FeaturePluginHost host) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (host.owner({'task': 'core-${'a' * 32}'}) != null &&
        DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Matcher code(String value) =>
      throwsA(isA<ServiceError>().having((e) => e.code, 'code', value));

  test('an embedded feature keeps its backend until restart', () async {
    final commands = <String, List<String>>{};
    final host = FeaturePluginHost(identity, commands: commands);
    addTearDown(host.dispose);
    expect(await host.call('reports', 'list', {}, () => {'local': 1}), {
      'local': 1,
    });
    commands['reports'] = fixture();
    expect(await host.call('reports', 'list', {}, () => {'local': 2}), {
      'local': 2,
    });
    expect(
      host.descriptors().firstWhere((f) => f['id'] == 'reports')['backend'],
      'embedded',
    );
    await host.shutdown();
  });

  test(
    'feature calls cannot invoke private worker lifecycle operations',
    () async {
      final service = CoreService(
        environment: identity.environment,
        migrate: false,
      );
      addTearDown(service.dispose);
      for (final operation in ['@hello', '@summary', '@shutdown', 'unknown']) {
        await expectLater(
          service.dispatchAsync('features.call', {
            'plugin': 'ai-project-center',
            'operation': operation,
            'params': <String, dynamic>{},
          }),
          throwsA(
            isA<ServiceError>().having(
              (e) => e.code,
              'code',
              'feature_operation_unknown',
            ),
          ),
        );
      }
    },
  );

  test('shutdown during startup prevents dispatch after closing', () async {
    final host = FeaturePluginHost(identity, commands: {'reports': fixture()});
    final operation = host.call('reports', 'list', {}, () => {});
    operation.ignore();
    await host.shutdown();
    await expectLater(operation, throwsA(isA<ServiceError>()));
  });

  test('domain Undo returns to the feature that issued its token', () async {
    final host = FeaturePluginHost(identity, commands: {'reports': fixture()});
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
      featureHost: host,
    );
    addTearDown(service.dispose);
    final result = await service.dispatchAsync('reports.list', {});
    final undo = await service.dispatchAsync('system.move_undo', {
      'undo': result['undo'],
    });
    expect(undo['method'], 'system.move_undo');
    expect(undo['echo'], {'undo': 'core-${'b' * 32}'});
    await service.shutdownFeatures();
  });

  test(
    'embedded fallback preserves operation and rejects closing calls',
    () async {
      final host = FeaturePluginHost(identity);
      expect(await host.call('reports', 'list', {}, () => {'local': true}), {
        'local': true,
      });
      await host.shutdown();
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        throwsA(isA<ServiceError>()),
      );
    },
  );

  test(
    'process protocol keeps concurrent calls and handle ownership separate',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture()},
      );
      addTearDown(host.dispose);
      final results = await Future.wait([
        host.call('reports', 'list', {
          'value': 'ü',
        }, () => throw StateError('fallback')),
        host.call('reports', 'get', {
          'value': 'other',
        }, () => throw StateError('fallback')),
      ]);
      expect(results[0]['echo'], {'value': 'ü'});
      expect(results[1]['echo'], {'value': 'other'});
      expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
      await host.shutdown();
    },
  );

  test(
    'incompatible process identity cannot receive a feature operation',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture('ask-ai')},
      );
      addTearDown(host.dispose);
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        throwsA(isA<ServiceError>()),
      );
    },
  );

  test(
    'a crashed plugin fails pending requests and is not silently replayed',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture()},
      );
      addTearDown(host.dispose);
      await expectLater(
        host.call('reports', 'crash', {}, () => {}),
        throwsA(isA<ServiceError>()),
      );
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        throwsA(isA<ServiceError>()),
      );
    },
  );

  test(
    'unsigned executable feature is refused before it can be started',
    () async {
      final directory = Directory('${identity.dataDir}/feature-plugins/reports')
        ..createSync(recursive: true);
      File('${directory.path}/feature.json').writeAsStringSync('{}');
      File('${directory.path}/SIGNATURE').writeAsStringSync('unsigned');
      File('${directory.path}/plugin').writeAsStringSync('must not execute');
      final host = FeaturePluginHost(identity);
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        throwsA(isA<ServiceError>()),
      );
    },
  );

  test('bare issued handles route back; same-shaped hashes do not', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'ask-ai': fixture('ask-ai')},
    );
    addTearDown(host.dispose);
    await host.call('ask-ai', 'map.smart_review', {}, () => {});
    expect(host.owner({'preview': 'c' * 32}), 'ask-ai');
    expect(host.owner({'undo': 'core-${'b' * 32}'}), 'ask-ai');
    expect(host.owner({'value': 'd' * 32}), isNull);
    await host.shutdown();
  });

  test(
    'a plugin without provenance is trusted only for prefixed handles',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'ask-ai': fixture('ask-ai', 'legacy')},
      );
      addTearDown(host.dispose);
      await host.call('ask-ai', 'map.smart_review', {}, () => {});
      expect(host.owner({'undo': 'core-${'b' * 32}'}), 'ask-ai');
      expect(host.owner({'preview': 'c' * 32}), isNull);
      await host.shutdown();
    },
  );

  test(
    'issued-handle provenance covers the bare form only for real tokens',
    () {
      final handle = newHandle();
      final bare = handle.substring(coreHandle.length);
      expect(issuedHandle(handle), isTrue);
      expect(issuedHandle(bare), isTrue);
      expect(issuedHandle('e' * 32), isFalse);
      expect(
        issuedHandlesIn({
          'a': [bare],
          'b': 'f' * 32,
        }),
        {bare},
      );
    },
  );

  test(
    'a refused Project Center shutdown leaves the other features usable',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {
          'reports': fixture(),
          'ai-project-center': fixture('ai-project-center', 'refuse-shutdown'),
        },
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      await host.call('ai-project-center', 'list', {}, () => {});
      await expectLater(
        host.shutdown(),
        throwsA(
          isA<ServiceError>().having(
            (e) => e.code,
            'code',
            'project_still_pausing',
          ),
        ),
      );
      final reports = await host.call('reports', 'list', {'x': 1}, () => {});
      expect(reports['echo'], {'x': 1});
      final project = await host.call(
        'ai-project-center',
        'list',
        {},
        () => {},
      );
      expect(project['method'], 'list');
      await host.shutdown();
    },
  );

  test(
    'a feature that confirms shutdown late is started again on use',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture('reports', 'slow-shutdown')},
        shutdownTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      await expectLater(
        host.shutdown(),
        throwsA(
          isA<ServiceError>().having(
            (e) => e.code,
            'code',
            'project_still_pausing',
          ),
        ),
      );
      // The late answer arrives and the process exits cleanly.
      await Future<void>.delayed(const Duration(seconds: 3));
      final result = await host.call('reports', 'list', {
        'again': true,
      }, () => {});
      expect(result['echo'], {'again': true});
    },
  );

  test(
    'no request queues behind a pending shutdown; concurrent shutdowns share one',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture('reports', 'slow-shutdown')},
        shutdownTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      final first = host.shutdown();
      final second = host.shutdown();
      expect(identical(first, second), isTrue);
      await expectLater(
        first,
        throwsA(
          isA<ServiceError>().having(
            (e) => e.code,
            'code',
            'project_still_pausing',
          ),
        ),
      );
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        throwsA(
          isA<ServiceError>().having((e) => e.code, 'code', 'feature_closing'),
        ),
      );
      // After the late confirmation a retry succeeds instead of asking again.
      await Future<void>.delayed(const Duration(seconds: 3));
      await host.shutdown();
    },
  );

  test(
    'a crashed plugin is started again after a pause, without replay',
    () async {
      final launches = '${temporary.path}/launches';
      var now = DateTime(2026);
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture('reports', '', launches)},
        clock: () => now,
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
      await expectLater(
        host.call('reports', 'crash', {}, () => {}),
        code('feature_disconnected'),
      );
      // Its handles died with it: a follow-up is not routed anywhere.
      expect(host.owner({'task': 'core-${'a' * 32}'}), isNull);
      // Within the pause nothing is started and nothing replayed, however
      // long the real wait.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_disconnected'),
      );
      expect(File(launches).readAsLinesSync(), hasLength(1));
      now = now.add(const Duration(seconds: 2));
      final again = await host.call('reports', 'list', {'n': 2}, () => {});
      expect(again['echo'], {'n': 2});
      expect(File(launches).readAsLinesSync(), hasLength(2));
      await host.shutdown();
    },
  );

  test('a failed backend is replaced only after it has exited', () async {
    final launches = '${temporary.path}/launches';
    var now = DateTime(2026);
    final host = FeaturePluginHost(
      identity,
      commands: {'reports': fixture('reports', 'barrier-exit', launches)},
      clock: () => now,
    );
    addTearDown(() {
      File('$launches.release').writeAsStringSync('');
      host.dispose();
    });
    await host.call('reports', 'list', {}, () => {});
    // An invalid frame fails it; SIGTERM ends it only once released.
    await expectLater(
      host.call('reports', 'garbage', {}, () => {}),
      code('feature_disconnected'),
    );
    // Past the pause, not yet at the kill.
    now = now.add(const Duration(seconds: 5));
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_disconnected'),
      );
    }
    expect(host.tracked('reports'), isTrue);
    expect(File(launches).readAsLinesSync(), hasLength(1));
    File('$launches.release').writeAsStringSync('');
    Map<String, dynamic>? again;
    for (var i = 0; i < 100 && again == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      try {
        again = await host.call('reports', 'list', {'n': 3}, () => {});
      } on ServiceError {
        // Not exited yet.
      }
    }
    expect(again?['echo'], {'n': 3});
    expect(File(launches).readAsLinesSync(), hasLength(2));
    await host.shutdown();
  });

  test(
    'a late-confirmed backend keeps its replacement\'s handles when it exits',
    () async {
      final launches = '${temporary.path}/launches';
      final host = FeaturePluginHost(
        identity,
        commands: {
          'reports': fixture('reports', 'slow-shutdown+barrier-exit', launches),
        },
        shutdownTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(() {
        File('$launches.release').writeAsStringSync('');
        host.dispose();
      });
      await host.call('reports', 'list', {}, () => {});
      await expectLater(host.shutdown(), code('project_still_pausing'));
      // The late confirmation arrives; the process has not exited yet.
      await Future<void>.delayed(const Duration(seconds: 2));
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_closing'),
      );
      File('$launches.release').writeAsStringSync('');
      Map<String, dynamic>? again;
      for (var i = 0; i < 100 && again == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        try {
          again = await host.call('reports', 'list', {'n': 4}, () => {});
        } on ServiceError {
          // Not exited yet.
        }
      }
      expect(again?['echo'], {'n': 4});
      expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
      // The old process's exit is noticed later; it must not take the
      // replacement's handles with it.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
    },
  );

  test('a process-backed feature does not turn embedded on restart', () async {
    var now = DateTime(2026);
    final commands = {'reports': fixture()};
    final host = FeaturePluginHost(
      identity,
      commands: commands,
      clock: () => now,
    );
    addTearDown(host.dispose);
    await host.call('reports', 'list', {}, () => {});
    await expectLater(
      host.call('reports', 'crash', {}, () => {}),
      code('feature_disconnected'),
    );
    commands.remove('reports');
    now = now.add(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    var embedded = false;
    await expectLater(
      host.call('reports', 'list', {}, () {
        embedded = true;
        return {};
      }),
      code('feature_disconnected'),
    );
    expect(embedded, isFalse);
  });

  test('a backend that could not start is tried again later', () async {
    final script = File('${temporary.path}/reports-plugin');
    final host = FeaturePluginHost(
      identity,
      commands: {
        'reports': [script.path],
      },
      restartDelay: const Duration(milliseconds: 100),
    );
    addTearDown(host.dispose);
    await expectLater(
      host.call('reports', 'list', {}, () => {}),
      code('feature_disconnected'),
    );
    final command = fixture().map((word) => "'$word'").join(' ');
    script.writeAsStringSync('#!/bin/sh\nexec $command\n');
    await Process.run('chmod', ['+x', script.path]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final result = await host.call('reports', 'list', {'ok': 1}, () => {});
    expect(result['echo'], {'ok': 1});
    await host.shutdown();
  });

  test('a broken update fails its feature only; listing stays cheap', () async {
    final directory = Directory('${identity.dataDir}/feature-plugins/reports')
      ..createSync(recursive: true);
    File('${directory.path}/feature.json').writeAsStringSync('{"id":');
    File('${directory.path}/SIGNATURE').writeAsStringSync('unsigned');
    File('${directory.path}/plugin').writeAsStringSync('must not execute');
    final host = FeaturePluginHost(identity);
    final features = host.descriptors();
    expect(features.map((f) => f['id']), unorderedEquals(featureIds));
    expect(
      features.firstWhere((f) => f['id'] == 'reports')['backend'],
      'process',
    );
    expect(
      Directory('${identity.cacheDir}/feature-launches').existsSync(),
      isFalse,
    );
    // Calling it surfaces the rejection; the bundled backend does not stand in.
    await expectLater(
      host.call('reports', 'list', {}, () => {'local': true}),
      code('feature_signature_invalid'),
    );
  });

  test(
    'an update under a linked data folder is read; a linked update is not',
    () async {
      final real = Directory('${temporary.path}/real')..createSync();
      Link('${temporary.path}/linked').createSync(real.path);
      final linked = AppIdentity(
        environment: {
          ...identity.environment,
          'XDG_DATA_HOME': '${temporary.path}/linked',
        },
      );
      final directory = Directory('${linked.dataDir}/feature-plugins/reports')
        ..createSync(recursive: true);
      // Too large to be a manifest: only a read that got past the folder
      // checks can tell.
      File(
        '${directory.path}/feature.json',
      ).writeAsBytesSync(List.filled(40000, 32));
      File('${directory.path}/SIGNATURE').writeAsStringSync('unsigned');
      File('${directory.path}/plugin').writeAsStringSync('must not execute');
      final host = FeaturePluginHost(linked);
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_too_large'),
      );
      // The update folder itself as a link is refused before reading.
      final elsewhere = Directory('${temporary.path}/elsewhere')..createSync();
      directory.renameSync('${elsewhere.path}/reports');
      Link(directory.path).createSync('${elsewhere.path}/reports');
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_signature_invalid'),
      );
    },
  );

  test('Ask AI gets the host context; other features do not', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'ask-ai': fixture('ask-ai'), 'reports': fixture()},
    );
    addTearDown(host.dispose);
    final asked = await host.call(
      'ask-ai',
      'map.smart_ask',
      {},
      () => {},
      context: () => {'catalog': [], 'mcp_check_forced': true},
    );
    expect(asked['context'], {'catalog': [], 'mcp_check_forced': true});
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
      featureHost: host,
    );
    addTearDown(service.dispose);
    final reports = await service.dispatchAsync('reports.list', {});
    expect(reports.containsKey('context'), isFalse);
    final viaHost = await service.dispatchAsync('map.smart_helpers', {});
    expect(
      (viaHost['context'] as Map).keys,
      containsAll(['catalog', 'updates', 'mcp_check_forced']),
    );
    await service.shutdownFeatures();
  });

  test('the host context keeps preview tokens with the host', () {
    final host = CoreService(environment: identity.environment, migrate: false);
    addTearDown(host.dispose);
    host.catalogRows = [
      {
        'id': 'x',
        'name': 'X',
        'kind': 'agent',
        'action': 'install',
        'preview': 'f' * 32,
      },
      {
        'id': 'y',
        'name': 'Y',
        'kind': 'provider',
        'action': '',
        'preview': null,
      },
    ];
    host.lastUpdates = [
      {
        'kind': 'agent',
        'key': 'agent:pi',
        'command': ['mise', 'upgrade', 'pi'],
      },
    ];
    final context = host.askAiHostContext();
    expect(jsonEncode(context), isNot(contains('f' * 32)));
    final worker = CoreService(
      environment: identity.environment,
      migrate: false,
      featureWorker: true,
    );
    addTearDown(worker.dispose);
    worker.applyAskAiHostContext(
      jsonDecode(jsonEncode(context)) as Map<String, dynamic>,
    );
    // Only offered rows travel; their token stays with the host.
    expect(worker.catalogRows.map((r) => r['preview']), ['host']);
    expect(worker.catalogRows.first['action'], 'install');
    expect(worker.lastUpdates.single['key'], 'agent:pi');
    // The updater the check found travels (it is checked again on use).
    expect(worker.lastUpdates.single['command'], ['mise', 'upgrade', 'pi']);
  });

  test('the indicator does not start an empty AI Project Center', () async {
    final launches = '${temporary.path}/launches';
    final host = FeaturePluginHost(
      identity,
      commands: {
        'ai-project-center': fixture('ai-project-center', '', launches),
      },
    );
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
      featureHost: host,
    );
    addTearDown(service.dispose);
    final summary = await service.dispatchAsync('features.summary', {});
    expect(summary['total'], 0);
    expect(summary['connected'], isTrue);
    expect(File(launches).existsSync(), isFalse);
    // Once something is stored, the backend answers.
    Directory(
      '${identity.dataDir}/ai-project-center',
    ).createSync(recursive: true);
    File(
      '${identity.dataDir}/ai-project-center/projects.json',
    ).writeAsStringSync('{}');
    await service.dispatchAsync('features.summary', {});
    expect(File(launches).readAsLinesSync(), hasLength(1));
    await service.shutdownFeatures();
  });

  test('the indicator reports a failed AI Project Center', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'ai-project-center': fixture('ai-project-center')},
    );
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
      featureHost: host,
    );
    addTearDown(service.dispose);
    await expectLater(
      service.dispatchAsync('features.call', {
        'plugin': 'ai-project-center',
        'operation': 'list',
        'params': <String, dynamic>{},
      }),
      completes,
    );
    await expectLater(
      host.call('ai-project-center', 'crash', {}, () => {}),
      code('feature_disconnected'),
    );
    await expectLater(
      service.dispatchAsync('features.summary', {}),
      code('feature_disconnected'),
    );
  });

  test('a follow-up to Ask AI carries no host context', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'ask-ai': fixture('ask-ai')},
    );
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
      featureHost: host,
    );
    addTearDown(service.dispose);
    final asked = await service.dispatchAsync('map.smart_helpers', {});
    expect(asked['context'], isNotNull);
    final followUp = await service.dispatchAsync('system.move_undo', {
      'undo': asked['undo'],
    });
    expect(followUp['method'], 'system.move_undo');
    expect(followUp.containsKey('context'), isFalse);
    await service.shutdownFeatures();
  });

  test('the host context stays within its bound', () {
    final service = CoreService(
      environment: identity.environment,
      migrate: false,
    );
    addTearDown(service.dispose);
    service.catalogRows = [
      for (var i = 0; i < 200; i++)
        {
          'id': 'addon-$i-${'x' * 150}',
          'name': 'Add-on $i ${'y' * 150}',
          'kind': 'agent',
          'action': 'install',
          'preview': 'f' * 32,
        },
    ];
    final context = service.askAiHostContext();
    expect(
      utf8.encode(jsonEncode(context)).length,
      lessThanOrEqualTo(maxAskAiContext),
    );
    expect(context['catalog'], isEmpty);
  });

  test(
    'a late-confirmed backend loses its handles at once and is killed if it hangs',
    () async {
      final launches = '${temporary.path}/launches';
      var now = DateTime(2026);
      final host = FeaturePluginHost(
        identity,
        commands: {
          'reports': fixture('reports', 'slow-shutdown+barrier-exit', launches),
        },
        shutdownTimeout: const Duration(milliseconds: 300),
        clock: () => now,
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
      await expectLater(host.shutdown(), code('project_still_pausing'));
      // Confirmed late, not exited (never released): its handles are gone.
      await confirmed(host);
      expect(host.owner({'task': 'core-${'a' * 32}'}), isNull);
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_closing'),
      );
      // A minute later it is killed, and then replaced.
      now = now.add(const Duration(minutes: 2));
      Map<String, dynamic>? again;
      for (var i = 0; i < 100 && again == null; i++) {
        try {
          again = await host.call('reports', 'list', {'n': 5}, () => {});
        } on ServiceError {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      expect(again?['echo'], {'n': 5});
      expect(File(launches).readAsLinesSync(), hasLength(2));
    },
  );

  test('a retried close ends a backend that exits on EOF', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'reports': fixture('reports', 'slow-shutdown+eof-exit')},
      shutdownTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(host.dispose);
    await host.call('reports', 'list', {}, () => {});
    await expectLater(host.shutdown(), code('project_still_pausing'));
    // The late confirmation arrives meanwhile; the retry needs no new call.
    await confirmed(host);
    await host.shutdown();
    expect(host.tracked('reports'), isTrue);
    expect(host.running('reports'), isFalse);
  });

  test(
    'an update\'s executable is not read before its signature passed',
    () async {
      final directory = Directory('${identity.dataDir}/feature-plugins/reports')
        ..createSync(recursive: true);
      File('${directory.path}/feature.json').writeAsStringSync('{}');
      File('${directory.path}/SIGNATURE').writeAsStringSync('unsigned');
      // Larger than allowed (sparse): reading it would answer "too large".
      final plugin = File(
        '${directory.path}/plugin',
      ).openSync(mode: FileMode.write);
      plugin.truncateSync(130 * 1024 * 1024);
      plugin.closeSync();
      final host = FeaturePluginHost(identity);
      await expectLater(
        host.call('reports', 'list', {}, () => {}),
        code('feature_signature_invalid'),
      );
    },
  );

  test('a handle its backend released routes no more', () async {
    final host = FeaturePluginHost(identity, commands: {'reports': fixture()});
    addTearDown(host.dispose);
    await host.call('reports', 'list', {}, () => {});
    expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
    expect(host.owner({'undo': 'core-${'b' * 32}'}), 'reports');
    await host.call('reports', 'release', {}, () => {});
    expect(host.owner({'task': 'core-${'a' * 32}'}), isNull);
    // What it still keeps routes on.
    expect(host.owner({'undo': 'core-${'b' * 32}'}), 'reports');
    await host.shutdown();
  });

  test(
    'releases in an error answer route no more; malformed ones fail it',
    () async {
      final host = FeaturePluginHost(
        identity,
        commands: {'reports': fixture()},
      );
      addTearDown(host.dispose);
      await host.call('reports', 'list', {}, () => {});
      await expectLater(
        host.call('reports', 'release-error', {}, () => {}),
        code('proposal_expired'),
      );
      expect(host.owner({'task': 'core-${'a' * 32}'}), isNull);
      expect(host.owner({'undo': 'core-${'b' * 32}'}), 'reports');
      await expectLater(
        host.call('reports', 'bad-release', {}, () => {}),
        code('feature_disconnected'),
      );
    },
  );

  test('a backend cannot release another feature\'s handle', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'reports': fixture(), 'ask-ai': fixture('ask-ai')},
    );
    addTearDown(host.dispose);
    await host.call('reports', 'list', {}, () => {});
    await host.call('ask-ai', 'release', {}, () => {});
    expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
    await host.shutdown();
  });

  test('answers arriving together apply issue and release in order', () async {
    final host = FeaturePluginHost(identity, commands: {'reports': fixture()});
    addTearDown(host.dispose);
    final issued = host.call('reports', 'pair-issue', {}, () => {});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final released = host.call('reports', 'pair-release', {}, () => {});
    expect((await issued)['task'], 'core-${'a' * 32}');
    await released;
    expect(host.owner({'task': 'core-${'a' * 32}'}), isNull);
    await host.shutdown();
  });

  test('a feature over its bound loses only its own oldest handles', () async {
    final host = FeaturePluginHost(
      identity,
      commands: {'reports': fixture(), 'ask-ai': fixture('ask-ai')},
      ownedLimit: 3,
    );
    addTearDown(host.dispose);
    // Reports keeps three handles, at its bound.
    await host.call('reports', 'list', {}, () => {});
    final first = await host.call('ask-ai', 'fresh', {}, () => {});
    for (var i = 0; i < 10; i++) {
      await host.call('ask-ai', 'fresh', {}, () => {});
    }
    expect(host.owner({'task': 'core-${'a' * 32}'}), 'reports');
    expect(host.owner({'undo': 'core-${'b' * 32}'}), 'reports');
    expect(host.owner({'h': first['handle']}), isNull);
    await host.shutdown();
  });
}
