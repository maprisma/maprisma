import 'package:maprisma_core/src/features/project_inventory.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:test/test.dart';

void main() {
  RuntimeRecord runtime() => RuntimeRecord('engine', 'Local engine')
    ..installed = true
    ..running = true
    ..address = '127.0.0.1:9090'
    ..models = ['coding/model', 'other', 'text-embedding'];
  Map<String, dynamic> provider([String name = 'configured']) => {
    'name': name,
    'local': true,
    'runtime': 'Local engine',
    'port': 9090,
  };
  Map<String, dynamic> agent(List<Map<String, dynamic>> providers) => {
    'id': 'worker',
    'models': [
      'configured/coding/model',
      'configured/unserved',
      'configured/text-embedding',
      'cloud/other',
    ],
    'providers': providers,
  };

  test('local bindings require configured and currently served chat IDs', () {
    final facts = projectRuntimeFacts(
      [runtime()],
      [
        agent([provider()]),
      ],
    );
    expect(facts.single['bindings'], {
      'worker': {
        'provider': 'configured',
        'models': ['coding/model'],
      },
    });
    expect(facts.single['models'], ['coding/model', 'other']);
    expect(facts.single.keys, isNot(contains('address')));
  });

  test('stale endpoint and nonlocal providers are never local bindings', () {
    for (final configured in [
      {...provider(), 'port': 8080},
      {...provider(), 'local': false},
    ]) {
      expect(
        projectRuntimeFacts(
          [runtime()],
          [
            agent([configured]),
          ],
        ).single['bindings'],
        isEmpty,
      );
    }
  });

  test(
    'ambiguous provider aliases require review instead of silent choice',
    () {
      expect(
        projectRuntimeFacts(
          [runtime()],
          [
            agent([provider(), provider('second'), provider('third')]),
          ],
        ).single['bindings'],
        isEmpty,
      );
    },
  );

  test('installed server switched off remains visible but unavailable', () {
    final rt = runtime()..serverOff = true;
    final facts = projectRuntimeFacts(
      [rt],
      [
        agent([provider()]),
      ],
    );
    expect(facts.single['installed'], true);
    expect(facts.single['running'], false);
  });

  test('dotted runtime names expose their conversational short name', () {
    final rt = RuntimeRecord('enginecpp', 'Engine.cpp');
    final facts = projectRuntimeFacts([rt], []);
    expect(facts.single['aliases'], ['enginecpp', 'Engine.cpp', 'Engine']);
  });

  test('long provider identities are kept separate from shortened labels', () {
    final id = 'configured-${'long'.padRight(44, 'x')}';
    final configured = {...provider(), 'id': id, 'name': id.substring(0, 40)};
    final facts = projectRuntimeFacts(
      [runtime()],
      [
        {
          ...agent([configured]),
          'models': ['$id/coding/model'],
        },
      ],
    );
    expect(facts.single['bindings'], {
      'worker': {
        'provider': id,
        'models': ['coding/model'],
      },
    });
  });

  test('a binding offers only models inside the runtime offered bound', () {
    final many = [for (var i = 0; i < 60; i++) 'm$i'];
    final rt = runtime()..models = many;
    final facts = projectRuntimeFacts(
      [rt],
      [
        {
          'id': 'worker',
          'models': [for (final model in many) 'configured/$model'],
          'providers': [provider()],
        },
      ],
    ).single;
    final offered = (facts['models'] as List).toSet();
    final bound =
        ((facts['bindings'] as Map)['worker'] as Map)['models'] as List;
    expect(offered, hasLength(maxRuntimeModels));
    expect(bound, isNotEmpty);
    expect(offered.containsAll(bound), isTrue);
  });
}
