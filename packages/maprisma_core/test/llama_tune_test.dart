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
  late String binary, used;
  late List<(List<String>, Map<String, String>)> runs;
  String? routerAnswer;

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
  });
  tearDown(() => root.deleteSync(recursive: true));

  LlamaTuner tuner() => LlamaTuner(
    home: root.path,
    environment: {'PATH': '/usr/bin:/bin', 'HOME': root.path},
    sysfs: '${root.path}/drm',
    sample: const Duration(milliseconds: 5),
    fetch: (url) async => url.endsWith('/models') ? routerAnswer : null,
    run: (argv, env, timeout) async {
      runs.add((argv, env));
      if (argv.contains('show')) {
        return (
          'ExecStart={ path=$binary ; argv[]=$binary --models-preset x ; ignore_errors=no }\n'
              'Environment=LD_LIBRARY_PATH=/opt/rocm/lib\n'
              'EnvironmentFiles=${root.path}/server.env (ignore_errors=no)\n',
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
      return ('[]', true);
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
  });

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
      throwsA(isA<FormatException>()),
    );
    expect(runs.where((r) => r.$1.first.endsWith('llama-bench')), isEmpty);
  });

  test('the section written, marked, and untuned models found', () {
    final m = {'name': 'Big', 'ctx': 131072, 'ubatch': 1024, 'batch': 2048};
    final text = tunedIniText('[*]\nctx-size = 8192\n', m, 'vulkan /x b12078');
    final section = text.split('[Big]')[1];
    for (final line in [
      '$tunedMarker vulkan /x b12078',
      'ctx-size = 131072',
      'ubatch-size = 1024',
      'batch-size = 2048',
      'cache-type-k = q8_0',
      'flash-attn = on',
    ]) {
      expect(section, contains(line));
    }
    // Measured again: one marker, the new one.
    final again = tunedIniText(text, m, 'rocm /y b12100');
    expect(tunedMarker.allMatches(again).length, 1);
    expect(untunedModels(again, ['Big', 'Other'], 'rocm /y b12100'), ['Other']);
    expect(untunedModels(again, ['Big'], 'vulkan /x b12078'), ['Big']);
    // The ini parser does not read the marker as a setting.
    expect(ContextReader.iniSections(again)['Big']!.keys, isNot(contains(';')));
  });
}
