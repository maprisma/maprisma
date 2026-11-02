import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('maprisma-dictation-test-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File writeExecutable(String dir, String name, String script) {
    Directory(dir).createSync(recursive: true);
    final file = File(p.join(dir, name))..writeAsStringSync(script);
    Process.runSync('chmod', ['+x', file.path]);
    return file;
  }

  test('defaults to enabled and unconfigured in an empty environment', () {
    final core = CoreService(
      environment: {
        'HOME': temp.path,
        'PATH': '${temp.path}/empty-bin',
        'MAPRISMA_DESKTOP': 'generic',
      },
    );
    final snap = core.dispatch('dictation.snapshot', {});
    expect(snap['enabled'], isTrue);
    expect(snap['engine'], 'auto');
    expect(snap['active'], '');
    expect(snap['ready'], isFalse);
    expect(snap['configured'], isFalse);
    expect(snap['cost_hint'], '');
    expect((snap['omarchy'] as Map)['supported'], isFalse);
    expect(() => core.dispatch('dictation.start', {}), throwsFormatException);
  });

  test(
    'auto priority prefers omarchy, then whisper, then local, then online',
    () {
      final fixture = {
        'omarchy': {
          'supported': true,
          'ready': true,
          'voxtype_installed': true,
          'monologue_installed': true,
          'label': 'Omarchy · Voxtype',
        },
        'whisper': {
          'program_installed': true,
          'ready': true,
          'active_model': 'ggml-base.bin',
        },
        'local': {
          'ready': true,
          'models': [
            {
              'runtime': 'llamacpp',
              'runtime_name': 'llama.cpp',
              'model': 'whisper-small',
              'running': true,
              'address': 'http://127.0.0.1:8080',
            },
          ],
        },
        'online': {'provider': 'OpenAI', 'ready': true},
        'text': 'Dictated sentence',
      };
      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
          'MAPRISMA_TEST_DICTATION': jsonEncode(fixture),
        },
      );
      var snap = core.dispatch('dictation.snapshot', {});
      expect(snap['active'], 'omarchy');
      expect(snap['ready'], isTrue);
      expect(snap['cost_hint'], '');

      core.dispatch('settings.update', {
        'values': {'dictation_engine': 'whisper'},
      });
      snap = core.dispatch('dictation.snapshot', {});
      expect(snap['active'], 'whisper');
      expect(snap['cost_hint'], '');

      core.dispatch('settings.update', {
        'values': {'dictation_engine': 'local'},
      });
      snap = core.dispatch('dictation.snapshot', {});
      expect(snap['active'], 'local');

      core.dispatch('settings.update', {
        'values': {'dictation_engine': 'online'},
      });
      snap = core.dispatch('dictation.snapshot', {});
      expect(snap['active'], 'online');
      expect(snap['cost_hint'], contains('OpenAI'));
      expect(snap['cost_hint'], contains('API credit'));

      final started = core.dispatch('dictation.start', {});
      expect(started['engine'], 'online');
      expect(started['mode'], 'wav');
      final stopped = core.dispatch('dictation.stop', {
        'recording': started['recording'],
      });
      expect(stopped['text'], 'Dictated sentence');
      expect(stopped['cost_hint'], contains('OpenAI'));
    },
  );

  test(
    'real Whisper CLI and recorder capture, transcribe and delete temp WAV',
    () {
      final binDir = '${temp.path}/bin';
      writeExecutable(
        binDir,
        'pw-record',
        '#!/bin/sh\n'
            'out=""\n'
            'for arg in "\$@"; do out="\$arg"; done\n'
            'echo "RIFF-fake-wav" > "\$out"\n'
            'trap "exit 0" INT TERM\n'
            'while :; do sleep 0.05; done\n',
      );
      writeExecutable(
        binDir,
        'whisper-cli',
        '#!/bin/sh\n'
            'echo "[BLANK_AUDIO]"\n'
            'echo "Hello from local Whisper"\n',
      );
      final modelDir = Directory(
        '${temp.path}/.local/share/maprisma/whisper/models',
      )..createSync(recursive: true);
      final modelFile = File('${modelDir.path}/ggml-base.bin')
        ..writeAsStringSync('model');

      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '$binDir:/usr/bin:/bin',
          'MAPRISMA_DESKTOP': 'generic',
        },
      );
      final snap = core.dispatch('dictation.snapshot', {});
      expect(snap['active'], 'whisper');
      expect(snap['ready'], isTrue);
      expect((snap['whisper'] as Map)['active_model'], 'ggml-base.bin');

      final started = core.dispatch('dictation.start', {});
      expect(started['mode'], 'wav');
      final stopped = core.dispatch('dictation.stop', {
        'recording': started['recording'],
      });
      expect(stopped['text'], 'Hello from local Whisper');
      expect(stopped['engine'], 'whisper');

      // Managed model can be removed; path traversal is refused.
      expect(
        () => core.dispatch('dictation.run', {
          'action': 'remove_whisper_model',
          'target': '../outside.bin',
        }),
        throwsFormatException,
      );
      core.dispatch('dictation.run', {
        'action': 'remove_whisper_model',
        'target': 'ggml-base.bin',
      });
      expect(modelFile.existsSync(), isFalse);
    },
  );

  test(
    'detects Omarchy dictation and Monologue and never leaks online API keys',
    () {
      final binDir = '${temp.path}/bin';
      writeExecutable(binDir, 'omarchy-dictation', '#!/bin/sh\nexit 0\n');
      writeExecutable(binDir, 'voxtype', '#!/bin/sh\nexit 0\n');
      writeExecutable(binDir, 'monologue', '#!/bin/sh\nexit 0\n');
      writeExecutable(binDir, 'pw-record', '#!/bin/sh\nexit 0\n');
      final defaultsDir = Directory('${temp.path}/.config/omarchy/defaults')
        ..createSync(recursive: true);
      File('${defaultsDir.path}/dictation').writeAsStringSync('voxtype\n');
      final codexDir = Directory('${temp.path}/.codex')
        ..createSync(recursive: true);
      File(
        '${codexDir.path}/.env',
      ).writeAsStringSync('OPENAI_API_KEY=sk-secret-do-not-leak\n');

      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '$binDir:/usr/bin:/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
        },
      );
      final snap = core.dispatch('dictation.snapshot', {});
      final encoded = jsonEncode(snap);
      expect(encoded, isNot(contains('sk-secret-do-not-leak')));
      expect((snap['omarchy'] as Map)['ready'], isTrue);
      expect((snap['omarchy'] as Map)['voxtype_installed'], isTrue);
      expect((snap['omarchy'] as Map)['monologue_installed'], isTrue);
      expect((snap['online'] as Map)['ready'], isTrue);
      expect((snap['online'] as Map)['provider'], 'OpenAI');
    },
  );
}
