import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:maprisma_core/src/context.dart';
import 'package:maprisma_core/src/llama_tune.dart';
import 'package:test/test.dart';

const gib = 1024 * 1024 * 1024;

/// A GGUF header (no tensors): a llama model with a KV cache.
List<int> gguf(int trained) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
  );
  void u64(int v) => out.add(
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List(),
  );
  void str(String s) {
    u64(utf8.encode(s).length);
    out.add(utf8.encode(s));
  }

  final ints = {
    'llama.context_length': trained,
    'llama.block_count': 32,
    'llama.attention.head_count': 32,
    'llama.attention.head_count_kv': 8,
    'llama.embedding_length': 4096,
  };
  out.add(ascii.encode('GGUF'));
  u32(3);
  u64(0);
  u64(1 + ints.length);
  str('general.architecture');
  u32(8);
  str('llama');
  for (final e in ints.entries) {
    str(e.key);
    u32(4);
    u32(e.value);
  }
  return out.toBytes();
}

/// Task 029: llama_tune measures with the build the service runs.
void main() {
  late Directory root;
  late String binary, used, execPath;
  late List<(List<String>, Map<String, String>)> runs;
  String? routerAnswer, ollamaAnswer;
  var mainPid = 0;
  var memoryRunFails = false;

  setUp(() {
    root = Directory.systemTemp.createTempSync('llama-tune-');
    Directory('${root.path}/llama').createSync();
    binary = '${root.path}/llama/llama-server';
    File(binary).writeAsStringSync('');
    File('${root.path}/llama/llama-bench').writeAsStringSync('');
    File('${root.path}/server.env').writeAsStringSync(
      '# comment\nLLAMA_ARG_PORT=8080\nGGML_VK_VISIBLE_DEVICES=0\n',
    );
    for (final (card, total) in [('card0', 512 << 20), ('card1', 24 * gib)]) {
      Directory('${root.path}/drm/$card/device').createSync(recursive: true);
      File(
        '${root.path}/drm/$card/device/mem_info_vram_total',
      ).writeAsStringSync('$total\n');
      File(
        '${root.path}/drm/$card/device/mem_info_vram_used',
      ).writeAsStringSync('${1 * gib}\n');
    }
    used = '${root.path}/drm/card1/device/mem_info_vram_used';
    Directory('${root.path}/models').createSync();
    File('${root.path}/models/Big.gguf').writeAsBytesSync(gguf(1048576));
    runs = [];
    routerAnswer = null;
    ollamaAnswer = null;
    mainPid = 0;
    memoryRunFails = false;
    execPath = binary;
  });
  tearDown(() => root.deleteSync(recursive: true));

  LlamaTuner tuner() => LlamaTuner(
    home: root.path,
    environment: {'PATH': '/usr/bin:/bin', 'HOME': root.path},
    sysfs: '${root.path}/drm',
    proc: '${root.path}/proc',
    sample: const Duration(milliseconds: 5),
    fetch: (url) async => url.endsWith('/models')
        ? routerAnswer
        : (url.endsWith('/api/ps') ? ollamaAnswer : null),
    run: (argv, env, timeout) async {
      runs.add((argv, env));
      if (argv.contains('show')) {
        return (
          'ExecStart={ path=$execPath ; argv[]=$execPath --models-preset x ; ignore_errors=no }\n'
              'Environment=LD_LIBRARY_PATH=/opt/rocm/lib\n'
              'EnvironmentFiles=${root.path}/server.env (ignore_errors=no)\n'
              'MainPID=$mainPid\n',
          true,
        );
      }
      if (argv.contains('--list-devices')) {
        return (
          'Available devices:\n  Vulkan0: AMD Radeon RX 7900 XTX (24560 MiB, 23372 MiB free)\n',
          true,
        );
      }
      if (argv.contains('--version')) return ('version: 12078 (abc)\n', true);
      final ub = argv[argv.indexOf('-ub') + 1];
      if (ub.contains(',')) {
        // 2048 is faster than 1024, but by less than 3 %: 1024 stays.
        const pp = {512: 8000.0, 1024: 8500.0, 2048: 8700.0};
        return (
          jsonEncode([
            for (final e in pp.entries) ...[
              {
                'n_ubatch': e.key,
                'n_prompt': 2048,
                'n_gen': 0,
                'avg_ts': e.value,
              },
              {'n_ubatch': e.key, 'n_prompt': 0, 'n_gen': 64, 'avg_ts': 235.0},
            ],
          ]),
          true,
        );
      }
      // The memory run: the card holds 6 GiB more while it runs.
      File(used).writeAsStringSync('${7 * gib}\n');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      File(used).writeAsStringSync('${1 * gib}\n');
      return ('[]', !memoryRunFails);
    },
  );

  test('the build the service runs, with its environment', () async {
    final built = (await tuner().build())!;
    expect(built.binary, binary);
    expect(built.kind, 'vulkan');
    expect(built.version, 'b12078');
    expect(built.environment['LD_LIBRARY_PATH'], '/opt/rocm/lib');
    expect(built.environment['GGML_VK_VISIBLE_DEVICES'], '0');
    expect(built.mark, 'vulkan ${root.path}/llama b12078');
    expect(built.script, isFalse);
  });

  test('a link in ExecStart: llama-bench next to the real binary', () async {
    Directory('${root.path}/bin').createSync();
    execPath = '${root.path}/bin/llama-server';
    Link(execPath).createSync(binary);
    final built = (await tuner().build())!;
    expect(built.binary, binary);
    expect(built.script, isFalse);
  });

  test(
    'a wrapper script: the running service\'s program and environment',
    () async {
      Directory('${root.path}/bin').createSync();
      execPath = '${root.path}/bin/llama-server';
      File(execPath).writeAsStringSync(
        '#!/usr/bin/env bash\nexport LD_LIBRARY_PATH=/rocm/lib\nexec $binary "\$@"\n',
      );
      // Stopped: the script is all there is; its build is not known.
      var built = (await tuner().build())!;
      expect(built.script, isTrue);
      await expectLater(
        tuner().measure(
          ['Big'],
          '${root.path}/models',
          '127.0.0.1:8080',
          '',
          (folder, name) => '$folder/$name.gguf',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('started by a script'),
          ),
        ),
      );
      // Running: the script exec'd the real binary, with its exports.
      mainPid = 4242;
      Directory('${root.path}/proc/4242').createSync(recursive: true);
      Link('${root.path}/proc/4242/exe').createSync(binary);
      File('${root.path}/proc/4242/environ').writeAsStringSync(
        'PATH=/usr/bin\x00LD_LIBRARY_PATH=/rocm/lib\x00ROCM_PATH=/rocm\x00',
      );
      built = (await tuner().build())!;
      expect(built.binary, binary);
      expect(built.script, isFalse);
      expect(built.environment['ROCM_PATH'], '/rocm');
      expect(built.environment['LD_LIBRARY_PATH'], '/rocm/lib');
      expect(built.devices, contains('Vulkan0: AMD Radeon RX 7900 XTX'));
      final version = runs.lastWhere((r) => r.$1.contains('--version'));
      expect(version.$1.first, binary);
      expect(version.$2['ROCM_PATH'], '/rocm');
    },
  );

  test(
    'the fastest batch size, the context from the measured memory',
    () async {
      final result = await tuner().measure(
        ['Big'],
        '${root.path}/models',
        '127.0.0.1:8080',
        '[*]\nctx-size = 8192\n',
        (folder, name) => '$folder/$name.gguf',
      );
      expect(result['build'], 'vulkan');
      expect(result['skipped'], isEmpty);
      final m = (result['models'] as List).single as Map;
      expect(m['ubatch'], 1024);
      expect(m['pp'], 8500);
      expect(m['tg'], 235);
      expect(m['used'], 6 * gib);
      final (perToken, _) = kvLayout(
        readGguf('${root.path}/models/Big.gguf'),
        'q8_0',
      );
      final room = 24 * gib - 1 * gib - tuneMargin - 6 * gib;
      expect(m['ctx'], (room ~/ perToken + 2064) ~/ 4096 * 4096);
      // The bench ran the service's build with its environment, q8_0 and
      // flash attention (nothing set in models.ini).
      final bench = runs.firstWhere((r) => r.$1.first.endsWith('llama-bench'));
      expect(bench.$1, containsAllInOrder(['-fa', '1', '-ctk', 'q8_0']));
      expect(bench.$2['LD_LIBRARY_PATH'], '/opt/rocm/lib');
    },
  );

  test('refused while a model holds the card', () async {
    routerAnswer = '{"data":[{"id":"x","status":{"value":"loaded"}}]}';
    await expectLater(
      tuner().measure(
        ['Big'],
        '${root.path}/models',
        '127.0.0.1:8080',
        '',
        (folder, name) => '$folder/$name.gguf',
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'The card is in use: a model is loaded in llama.cpp. Measure again when it is idle.',
        ),
      ),
    );
    expect(runs.where((r) => r.$1.first.endsWith('llama-bench')), isEmpty);
  });

  test('something else on Ollama\'s port does not stop it', () async {
    ollamaAnswer = '<html>not ollama</html>';
    final result = await tuner().measure(
      ['Big'],
      '${root.path}/models',
      '127.0.0.1:8080',
      '',
      (folder, name) => '$folder/$name.gguf',
    );
    expect((result['models'] as List).single['name'], 'Big');
  });

  test('a memory run that does not finish: skipped, no context', () async {
    memoryRunFails = true;
    final result = await tuner().measure(
      ['Big'],
      '${root.path}/models',
      '127.0.0.1:8080',
      '',
      (folder, name) => '$folder/$name.gguf',
    );
    expect(result['models'], isEmpty);
    expect(
      (result['skipped'] as List).single['reason'],
      'llama-bench did not finish',
    );
  });

  test('the section written', () {
    final m = {'name': 'Big', 'ctx': 131072, 'ubatch': 1024, 'batch': 2048};
    final text = tunedIniText('[*]\nctx-size = 8192\n', m);
    final section = text.split('[Big]')[1];
    for (final line in [
      'ctx-size = 131072',
      'ubatch-size = 1024',
      'batch-size = 2048',
      'cache-type-k = q8_0',
      'flash-attn = on',
    ]) {
      expect(section, contains(line));
    }
  });

  test('the record: measured and skipped models count, per build', () {
    final at = DateTime.utc(2026, 11, 4);
    var record = withMeasurement(
      {'models': {}},
      {
        'mark': 'vulkan /x b12078',
        'build': 'vulkan',
        'build_path': '/x/llama-server',
        'version': 'b12078',
        'models': [
          {'name': 'Big', 'ctx': 131072, 'ubatch': 1024, 'pp': 8500, 'tg': 235},
        ],
        'skipped': [
          {'name': 'Whisper', 'reason': 'its memory per token is not known'},
        ],
      },
      at,
    );
    final big = (record['models'] as Map)['Big'] as Map;
    expect(big['ctx'], 131072);
    expect(big['date'], '2026-11-04T00:00:00.000Z');
    expect(
      untunedModels(record, ['Big', 'Whisper', 'New'], 'vulkan /x b12078'),
      ['New'],
    );
    // Another build: all of them again.
    expect(untunedModels(record, ['Big', 'Whisper'], 'rocm /y b12100'), [
      'Big',
      'Whisper',
    ]);
    // Written and read back.
    final path = '${root.path}/state/llm-tuning.json';
    Directory('${root.path}/state').createSync();
    File(path).writeAsStringSync(jsonEncode(record));
    record = readTuningRecord(path);
    expect(untunedModels(record, ['Big'], 'vulkan /x b12078'), isEmpty);
    expect(readTuningRecord('${root.path}/none.json'), {'models': {}});
  });
}
