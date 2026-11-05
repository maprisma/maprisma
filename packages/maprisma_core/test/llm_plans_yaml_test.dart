// Review 063 round 5: a Hermes or Oh My Pi provider whose YAML key is quoted is
// the same entry when it is rewritten (a Repair of a moved local LLM).
import 'package:maprisma_core/src/llm_plans.dart';
import 'package:maprisma_core/src/local_llm.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  for (final key in [
    'workstation',
    '"workstation"',
    "'workstation'",
    'workstation ',
  ]) {
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

  // Review 063 round 6: one reader for every providers key (writer, "is
  // connected", model readers); what it cannot read safely stops the edit.
  String withKey(String key) =>
      'providers:\n'
      '  $key:\n'
      '    default_model: qwen\n'
      '    models:\n'
      '      qwen: {}\n'
      '  workstation2:\n'
      '    models: []\n';

  String rewrite(String before) => hermesLlmText(
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

  test('keys are read decoded, in every plain spelling', () {
    for (final key in [
      'workstation',
      '"workstation"',
      "'workstation'",
      'workstation ',
    ]) {
      expect(LocalLlm.providerKeys(withKey(key)), [
        'workstation',
        'workstation2',
      ]);
    }
    expect(LocalLlm.providerKeys(withKey("'it''s'")), ["it's", 'workstation2']);
  });

  test('an escaped, flow or oddly indented key stops the rewrite', () {
    for (final key in [
      r'"\u0077orkstation"',
      '? workstation',
      '{a: b}',
      ' workstation',
      '&a workstation',
    ]) {
      final before = withKey(key);
      expect(() => rewrite(before), throwsFormatException, reason: key);
      expect(LocalLlm.providerKeys(before), isEmpty, reason: key);
    }
  });

  test('a provider name that needs quoting is not written bare', () {
    expect(
      () => hermesLlmText(
        '',
        'a: b',
        'x',
        'http://h/v1',
        const [],
        const {},
        '',
        false,
        false,
      ),
      throwsFormatException,
    );
  });

  test('only the entry of that exact name is replaced', () {
    final after = rewrite(withKey('"workstation"'));
    final providers = (loadYaml(after) as Map)['providers'] as Map;
    expect(providers.keys.toSet(), {'workstation', 'workstation2'});
    expect('${providers['workstation']}', contains('127.0.0.1:9090'));
  });
}
