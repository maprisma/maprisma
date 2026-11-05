import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/agent_details.dart';
import 'package:maprisma_core/src/desktop.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/service_i18n.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

/// The details readers (Python: agent_readers, tests/test_agent_details.py):
/// the model and provider each agent's own files name.
void main() {
  late Directory home;
  late Map<String, String> env;
  DetailReaders readers() {
    final identity = AppIdentity(environment: env);
    return DetailReaders(
      ScanFiles(identity),
      GenericDesktop(env),
      ServiceI18n(identity, SettingsStore(identity)),
    );
  }

  File write(String path, String text) => File('${home.path}/$path')
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  Adapter adapter(String command) =>
      builtinAdapters().firstWhere((a) => a.command == command);

  setUp(() {
    home = Directory.systemTemp.createTempSync('agent-readers');
    env = {
      'HOME': home.path,
      'XDG_CONFIG_HOME': '${home.path}/.config',
      'XDG_DATA_HOME': '${home.path}/.local/share',
      'XDG_STATE_HOME': '${home.path}/.local/state',
      'PATH': '/usr/bin:/bin',
    };
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('Claude: the model of its last session, as the map\'s alias', () {
    // test_claude_model_from_its_last_session
    final details = readers();
    write('.claude/settings.json', '{"theme": "dark"}');
    expect(details.claudeSessionModel(), ''); // no sessions yet
    final old = write(
      '.claude/projects/-a/old.jsonl',
      '{"message":{"model":"claude-sonnet-5-5"}}\n',
    );
    old.setLastModifiedSync(
      DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
    );
    // Only a session older than a month: still the model it ran.
    expect(readers().claudeSessionModel(), 'sonnet');
    write(
      '.claude/projects/-b/new.jsonl',
      '{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}\n'
          '{"type":"assistant","message":{"model":"<synthetic>"}}\n'
          '{"type":"assistant","message":{"model":"claude-opus-5-5"}}\n',
    );
    expect(details.claudeSessionModel(), 'opus');
    expect(details.read(adapter('claude')).model, 'opus');
    write(
      '.claude/projects/-b/new.jsonl',
      '{"message":{"model":"claude-haiku-5-5"}}\n',
    );
    // No alias: its own name.
    expect(details.claudeSessionModel(), 'claude-haiku-5-5');
    write('.claude/settings.json', '{"model": "sonnet"}');
    expect(details.read(adapter('claude')).model, 'sonnet'); // set: as it is
  });

  test('Claude: a resumed old project counts by its file\'s time', () {
    write('.claude/settings.json', '{}');
    final old = write(
      '.claude/projects/-old/s.jsonl',
      '{"message":{"model":"claude-sonnet-5-5"}}\n',
    );
    for (var n = 0; n < 20; n++) {
      write(
        '.claude/projects/-p$n/s.jsonl',
        '{"message":{"model":"claude-haiku-5-5"}}\n',
      ).setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch((1700000000 + n) * 1000),
      );
    }
    old.setLastModifiedSync(
      DateTime.fromMillisecondsSinceEpoch(1800000000 * 1000),
    );
    expect(readers().claudeSessionModel(), 'sonnet');
  });

  void age(File file, int seconds) => file.setLastModifiedSync(
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
  );

  test('Gemini CLI: its settings, else its newest session', () {
    // test_gemini_model_from_settings_else_its_newest_session
    String model() => readers().read(adapter('gemini')).model;
    expect(model(), '');
    age(
      write(
        '.gemini/tmp/p1/chats/session-1.jsonl',
        '{"type":"gemini","model":"gemini-2.5-pro","tokens":{"input":1}}\n',
      ),
      1700000000,
    );
    write(
      '.gemini/tmp/p2/chats/session-2.json',
      '{"messages":[{"type":"user","content":"x"},'
          '{"type":"gemini","model":"gemini-3.1-pro","tokens":{"input":1}},'
          '{"type":"gemini","model":"gemini-3-flash","tokens":{"input":1}}]}',
    );
    expect(model(), 'gemini-3-flash');
    write(
      '.gemini/tmp/p1/chats/parent/sub.jsonl', // a subagent, written last
      '{"type":"gemini","model":"gemini-3.8-flash","tokens":{"input":1}}\n',
    );
    expect(model(), 'gemini-3.8-flash');
    write('.gemini/settings.json', '{"model": {"name": "gemini-2.5-flash"}}');
    expect(model(), 'gemini-2.5-flash');
    write('.gemini/settings.json', '{"model": "gemini-2.5-pro"}'); // older
    expect(model(), 'gemini-2.5-pro');
  });

  test('Grok: the model of its newest session', () {
    // test_grok_model_from_its_newest_session
    String model() => readers().read(adapter('grok')).model;
    expect(model(), '');
    age(
      write(
        '.grok/sessions/a/s1/usage.json',
        '{"turns":[{"endedAt":"x","modelUsage":'
            '{"grok-4.6":{"inputTokens":5,"outputTokens":1}}}]}',
      ),
      1700000000,
    );
    write(
      '.grok/sessions/b/s2/usage.json',
      jsonEncode({
        'turns': [
          {
            'modelUsage': {
              'grok-4.6': {'inputTokens': 9},
            },
          },
          {
            'modelUsage': {
              'grok-build-0.1': {'inputTokens': 10, 'outputTokens': 1},
              'grok-4.7': {'inputTokens': 900, 'outputTokens': 20},
            },
          },
          {'endedAt': null},
        ],
      }),
    );
    expect(model(), 'grok-4.7');
  });

  test('Crush: its model and providers from crush.json', () {
    // test_crush_model_and_providers_from_its_config
    expect(readers().read(adapter('crush')).model, '');
    write(
      '.config/crush/crush.json',
      jsonEncode({
        'models': {
          'large': {'model': 'qwen3', 'provider': 'ollama'},
          'small': {'model': 'claude-haiku-4-5', 'provider': 'anthropic'},
        },
        'providers': {
          'ollama': {
            'type': 'openai',
            'base_url': 'http://localhost:11434/v1/',
            'models': [
              {'id': 'qwen3'},
              {'id': 'gemma3'},
            ],
          },
          'work': {'type': 'openai', 'base_url': 'https://llm.example.com/v1'},
        },
      }),
    );
    final info = readers().read(adapter('crush'));
    expect(info.model, 'qwen3 (ollama)');
    expect(
      [
        for (final p in info.providers)
          [p['name'], p['local'], p['runtime'], p['models'], p['active']],
      ],
      [
        ['ollama', true, 'Ollama', 2, true],
        ['work', false, '', 0, false],
      ],
    );
    write(
      '.config/crush/crush.json',
      '{"models": {"large": {"model": "claude-sonnet-5-5", '
          '"provider": "anthropic"}}}',
    );
    expect(
      readers().read(adapter('crush')).model,
      'claude-sonnet-5-5 (anthropic)',
    );
  });
}
