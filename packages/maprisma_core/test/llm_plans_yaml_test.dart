// Review 063 round 5: a Hermes or Oh My Pi provider whose YAML key is quoted is
// the same entry when it is rewritten (a Repair of a moved local LLM).
import 'package:maprisma_core/src/llm_plans.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  for (final key in ['workstation', '"workstation"', "'workstation'"]) {
    test('a Hermes provider written as $key is rewritten, not doubled', () {
      final before =
          'model:\n'
          '  default: qwen\n'
          '  provider: openai\n'
          'providers:\n'
          '  $key:\n'
          '    name: workstation\n'
          '    base_url: http://127.0.0.1:8080/v1\n'
          '    models:\n'
          '    - qwen\n';
      expect(loadYaml(before), isA<Map>());
      final after = hermesLlmText(
        before,
        'workstation',
        'workstation',
        'http://127.0.0.1:9090/v1',
        ['qwen'],
        const {},
        'qwen',
        false,
        false,
      );
      final parsed = loadYaml(after) as Map; // a doubled key would throw
      final providers = parsed['providers'] as Map;
      expect(providers.keys, ['workstation']);
      expect('${providers['workstation']}', contains('127.0.0.1:9090'));
      expect(after, isNot(contains('127.0.0.1:8080')));
    });
  }
}
