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

  test(
    'defaults to enabled and unconfigured, and serializes readable ServiceError message',
    () async {
      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/empty-bin',
          'MAPRISMA_DESKTOP': 'generic',
        },
      );
      final snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['enabled'], isTrue);
      expect(snap['engine'], 'auto');
      expect(snap['active'], '');
      expect(snap['ready'], isFalse);
      expect(snap['configured'], isFalse);
      expect(snap['cost_hint'], '');
      expect((snap['omarchy'] as Map)['supported'], isFalse);

      final response =
          jsonDecode(
                await core.handleAsync(
                  jsonEncode({
                    'protocol': 2,
                    'id': 1,
                    'method': 'dictation.start',
                    'params': const <String, dynamic>{},
                  }),
                ),
              )
              as Map<String, dynamic>;
      final error = response['error'] as Map<String, dynamic>;
      expect(error['code'], 'action_refused');
      expect(error['message'], 'Dictation is not set up yet.');
    },
  );

  test(
    'auto priority prefers omarchy, then whisper, then local, then online',
    () async {
      final fixture = {
        'omarchy': {
          'supported': true,
          'ready': true,
          'voxtype_installed': true,
          'monologue_installed': true,
          'default_tool': 'voxtype',
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
      var snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['active'], 'omarchy');
      expect(snap['ready'], isTrue);
      expect(snap['cost_hint'], '');

      await core.dispatchAsync('settings.update', {
        'values': {'dictation_engine': 'whisper'},
      });
      snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['active'], 'whisper');
      expect(snap['cost_hint'], '');

      await core.dispatchAsync('settings.update', {
        'values': {'dictation_engine': 'local'},
      });
      snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['active'], 'local');

      await core.dispatchAsync('settings.update', {
        'values': {'dictation_engine': 'online'},
      });
      snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['active'], 'online');
      expect(snap['cost_hint'], contains('OpenAI'));
      expect(snap['cost_hint'], contains('API credit'));

      final started = await core.dispatchAsync('dictation.start', {});
      expect(started['engine'], 'online');
      expect(started['mode'], 'wav');
      final stopped = await core.dispatchAsync('dictation.stop', {
        'recording': started['recording'],
      });
      expect(stopped['text'], 'Dictated sentence');
      expect(stopped['cost_hint'], contains('OpenAI'));
    },
  );

  test(
    'real Whisper CLI, model selection, LLM ggml filtering, transcription-only elapsed_ms, and recorder cleanup on cancel/dispose',
    () async {
      final binDir = '${temp.path}/bin';
      final pidFile = File('${temp.path}/pw-record.pid');
      writeExecutable(
        binDir,
        'pw-record',
        '#!/bin/sh\n'
            'echo "\$\$" > "${pidFile.path}"\n'
            'out=""\n'
            'for arg in "\$@"; do out="\$arg"; done\n'
            'echo "RIFF-fake-wav" > "\$out"\n'
            'trap "rm -f \\"${pidFile.path}\\"; exit 0" INT TERM\n'
            'while :; do sleep 0.05; done\n',
      );
      final modelSeenFile = File('${temp.path}/whisper-model-seen.txt');
      writeExecutable(
        binDir,
        'whisper-cli',
        '#!/bin/sh\n'
            'prev=""\n'
            'for arg in "\$@"; do\n'
            '  if [ "\$prev" = "-m" ]; then echo "\$arg" > "${modelSeenFile.path}"; fi\n'
            '  prev="\$arg"\n'
            'done\n'
            'echo "[BLANK_AUDIO]"\n'
            'echo "Hello from local Whisper"\n',
      );
      final modelDir = Directory(
        '${temp.path}/.local/share/maprisma/whisper/models',
      )..createSync(recursive: true);
      final baseFile = File('${modelDir.path}/ggml-base.bin')
        ..writeAsStringSync('model');
      final turboFile = File('${modelDir.path}/ggml-large-v3-turbo-q5_0.bin')
        ..writeAsStringSync('model');
      // A half-downloaded .part file must never be listed or chosen.
      final partFile = File('${modelDir.path}/ggml-small.bin.part')
        ..writeAsStringSync('partial');
      // Old llama.cpp GGML LLM file in ~/Models must NOT count as a Whisper model.
      final llmModelsDir = Directory('${temp.path}/Models')
        ..createSync(recursive: true);
      File(
        '${llmModelsDir.path}/ggml-alpaca-7b-q4_0.bin',
      ).writeAsStringSync('llm');

      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '$binDir:/usr/bin:/bin',
          'MAPRISMA_DESKTOP': 'generic',
        },
      );
      var snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(snap['active'], 'whisper');
      expect(snap['ready'], isTrue);
      final whisper = snap['whisper'] as Map<String, dynamic>;
      final modelNames = (whisper['models'] as List)
          .cast<Map>()
          .map((m) => m['name'])
          .toList();
      expect(modelNames, ['ggml-base.bin', 'ggml-large-v3-turbo-q5_0.bin']);
      expect(modelNames, isNot(contains('ggml-small.bin.part')));
      expect(modelNames, isNot(contains('ggml-alpaca-7b-q4_0.bin')));
      expect(partFile.existsSync(), isTrue);
      // By default, higher-accuracy starter model is preferred over alphabetical order.
      expect(whisper['active_model'], 'ggml-large-v3-turbo-q5_0.bin');

      // Select ggml-base.bin explicitly and verify it becomes active, then switch back to turbo.
      await core.dispatchAsync('dictation.run', {
        'action': 'select_whisper_model',
        'target': 'ggml-base.bin',
      });
      snap = await core.dispatchAsync('dictation.snapshot', {});
      expect((snap['whisper'] as Map)['active_model'], 'ggml-base.bin');

      await core.dispatchAsync('dictation.run', {
        'action': 'select_whisper_model',
        'target': 'ggml-large-v3-turbo-q5_0.bin',
      });
      snap = await core.dispatchAsync('dictation.snapshot', {});
      expect(
        (snap['whisper'] as Map)['active_model'],
        'ggml-large-v3-turbo-q5_0.bin',
      );

      final started = await core.dispatchAsync('dictation.start', {});
      expect(started['mode'], 'wav');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(pidFile.existsSync(), isTrue);

      final stopped = await core.dispatchAsync('dictation.stop', {
        'recording': started['recording'],
      });
      expect(stopped['text'], 'Hello from local Whisper');
      expect(stopped['engine'], 'whisper');
      // Recorder was stopped and cleaned up.
      expect(pidFile.existsSync(), isFalse);
      // Selected model was passed to whisper-cli.
      expect(
        modelSeenFile.readAsStringSync().trim(),
        endsWith('ggml-large-v3-turbo-q5_0.bin'),
      );

      // Start another recording, then dispose CoreService -> kills recorder immediately.
      await core.dispatchAsync('dictation.start', {});
      for (var i = 0; i < 20 && !pidFile.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(pidFile.existsSync(), isTrue);
      core.dispose();
      for (var i = 0; i < 20 && pidFile.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(pidFile.existsSync(), isFalse);

      // Managed model can be removed; path traversal is refused.
      await expectLater(
        core.dispatchAsync('dictation.run', {
          'action': 'remove_whisper_model',
          'target': '../outside.bin',
        }),
        throwsFormatException,
      );
      await core.dispatchAsync('dictation.run', {
        'action': 'remove_whisper_model',
        'target': 'ggml-base.bin',
      });
      expect(baseFile.existsSync(), isFalse);
      expect(turboFile.existsSync(), isTrue);
    },
  );

  test(
    'Omarchy readiness requires default_tool to match an installed backend, Monologue is not a dictation backend, and online curl uses stdin -K -',
    () async {
      final binDir = '${temp.path}/bin';
      writeExecutable(binDir, 'omarchy-dictation', '#!/bin/sh\nexit 0\n');
      writeExecutable(binDir, 'voxtype', '#!/bin/sh\nexit 0\n');
      writeExecutable(binDir, 'monologue', '#!/bin/sh\nexit 0\n');
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
      final curlStdinFile = File('${temp.path}/curl-stdin.txt');
      writeExecutable(
        binDir,
        'curl',
        '#!/bin/sh\n'
            'cat > "${curlStdinFile.path}"\n'
            'echo "Transcribed by online curl"\n',
      );

      final core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '$binDir:/usr/bin:/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
        },
      );

      // Without ~/.config/omarchy/defaults/dictation, neither voxtype nor monologue makes Omarchy ready or configured.
      var snap = await core.dispatchAsync('dictation.snapshot', {});
      expect((snap['omarchy'] as Map)['voxtype_installed'], isTrue);
      expect((snap['omarchy'] as Map)['monologue_installed'], isTrue);
      expect((snap['omarchy'] as Map)['ready'], isFalse);
      expect(snap['configured'], isFalse);
      expect(snap['ready'], isFalse);

      // With defaults/dictation set to voxtype, Omarchy becomes ready.
      final defaultsDir = Directory('${temp.path}/.config/omarchy/defaults')
        ..createSync(recursive: true);
      File('${defaultsDir.path}/dictation').writeAsStringSync('voxtype\n');
      final codexDir = Directory('${temp.path}/.codex')
        ..createSync(recursive: true);
      File(
        '${codexDir.path}/.env',
      ).writeAsStringSync('OPENAI_API_KEY=sk-secret-do-not-leak\n');

      snap = await core.dispatchAsync('dictation.snapshot', {});
      final encoded = jsonEncode(snap);
      expect(encoded, isNot(contains('sk-secret-do-not-leak')));
      expect((snap['omarchy'] as Map)['ready'], isTrue);
      expect((snap['omarchy'] as Map)['default_tool'], 'voxtype');
      expect((snap['online'] as Map)['ready'], isTrue);

      // Online transcription pipes Authorization header via curl -K - stdin.
      await core.dispatchAsync('settings.update', {
        'values': {'dictation_engine': 'online'},
      });
      final started = await core.dispatchAsync('dictation.start', {});
      final stopped = await core.dispatchAsync('dictation.stop', {
        'recording': started['recording'],
      });
      expect(stopped['text'], 'Transcribed by online curl');
      expect(
        curlStdinFile.readAsStringSync(),
        contains('Authorization: Bearer sk-secret-do-not-leak'),
      );

      // Verify update_omarchy updates only installed packages without -Syu, and whisper uses AUR helper without -Syu.
      final termArgsFile = File('${temp.path}/term-args.txt');
      writeExecutable(
        binDir,
        'omarchy-launch-floating-terminal-with-presentation',
        '#!/bin/sh\n'
            'echo "\$@" >> "${termArgsFile.path}"\n',
      );
      writeExecutable(
        binDir,
        'xdg-terminal-exec',
        '#!/bin/sh\n'
            'echo "\$@" >> "${termArgsFile.path}"\n',
      );
      writeExecutable(binDir, 'yay', '#!/bin/sh\nexit 0\n');
      await core.dispatchAsync('dictation.run', {'action': 'update_omarchy'});
      await core.dispatchAsync('dictation.run', {'action': 'install_whisper'});
      await core.dispatchAsync('dictation.run', {
        'action': 'download_whisper_model',
        'target': 'small',
      });
      await core.dispatchAsync('dictation.run', {'action': 'update_whisper'});
      for (
        var i = 0;
        i < 20 &&
            (!termArgsFile.existsSync() ||
                termArgsFile.readAsLinesSync().length < 4);
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final termLines = termArgsFile.readAsStringSync();
      expect(termLines, isNot(contains('-Syu')));
      expect(termLines, contains('sudo pacman -S voxtype-bin monologue'));
      expect(termLines, isNot(contains('superwhisper-bin')));
      expect(
        termLines,
        anyOf(
          contains('omarchy-pkg-aur-add whisper.cpp'),
          contains('yay -S --needed whisper.cpp'),
        ),
      );
      expect(termLines, contains('ggml-base.bin.part'));
      expect(termLines, contains('mv -f'));
      expect(termLines, contains('ggml-small.bin.part'));
      expect(termLines, contains('yay -S whisper.cpp'));
    },
  );
}
