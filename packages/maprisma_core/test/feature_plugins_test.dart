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
  List<String> fixture([String id = 'reports', String mode = '']) => [
    Platform.resolvedExecutable,
    File('test/fixtures/feature_plugin_fixture.dart').absolute.path,
    id,
    if (mode.isNotEmpty) mode,
  ];

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
}
