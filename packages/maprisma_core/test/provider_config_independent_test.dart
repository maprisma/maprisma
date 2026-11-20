import 'dart:convert';
import 'dart:io';

import 'package:maprisma_core/src/context.dart';
import 'package:maprisma_core/src/provider_config.dart';
import 'package:maprisma_core/src/provider_config_files.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/adapters.dart';
import 'package:maprisma_core/src/smart_card.dart';
import 'package:maprisma_core/src/provider_ops.dart';
import 'package:test/test.dart';

import 'support/provider_config_fixture.dart';

void main() {
  for (final vram in [0, gib ~/ 2]) {
    test('Strata advice remains available with $vram bytes of VRAM', () {
      final home = Directory.systemTemp.createTempSync('strata-advice-config');
      addTearDown(() => home.deleteSync(recursive: true));
      final service = CoreService(
        environment: {
          'HOME': home.path,
          'PATH': '',
          'MAPRISMA_DESKTOP': 'generic',
        },
        migrate: false,
      );
      addTearDown(service.dispose);
      final facts = configFixture(key: 'strata', vram: vram, available: vram)
        ..['writable'] = false
        ..['models'] = <Map<String, dynamic>>[];
      service.configCache.keep('strata', facts);
      final math = ConfigMath(facts, '');
      expect(math.fit({})['basis'], 'ram');
      expect(math.validate({})['errors'], isEmpty);
      expect(
        (math.recommend('balanced')['recommended'] as List).any(
          (row) => '${row['reason']}'.contains('too large for this GPU'),
        ),
        false,
      );
      final check = service.configRoute('models.config_check', {
        'key': 'strata',
        'values': <String, dynamic>{},
      });
      expect(check['errors'], isEmpty);
      expect(check['snippet'], 'strata launch');
      expect(
        configAnswer({'summary': 'Use launch advice', 'values': {}}, facts, ''),
        isNot(contains('error')),
      );
    });
  }

  test('Ask AI Call 1 lists at most forty installed chat models', () async {
    final home = Directory.systemTemp.createTempSync('config-call-one-models');
    addTearDown(() => home.deleteSync(recursive: true));
    void write(String path, String text) {
      final file = File('${home.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    for (final command in ['claude', 'llama-server']) {
      write('bin/$command', '#!/bin/sh\necho fixture\n');
      Process.runSync('chmod', ['+x', '${home.path}/bin/$command']);
    }
    for (var i = 0; i < 45; i++) {
      write('.cache/llama.cpp/chat-$i.gguf', 'fixture');
    }
    write('.cache/llama.cpp/nomic-embed.gguf', 'fixture');
    write('.cache/llama.cpp/whisper-small.gguf', 'fixture');
    write('worker', '''#!/usr/bin/python3
import json, pathlib, sys
request = json.loads(sys.stdin.buffer.readline())
size = int(sys.stdin.buffer.readline())
body = sys.stdin.buffer.read(size)
pathlib.Path(__file__).with_name('captured.json').write_bytes(body)
print(json.dumps({'type':'result','result':{'status':'answer','summary':'Fixture answer','helper':'claude','local':False}}))
''');
    Process.runSync('chmod', ['+x', '${home.path}/worker']);
    final service = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '${home.path}/bin',
        'MAPRISMA_DESKTOP': 'generic',
        'MAPRISMA_SCAN_GPU': '${home.path}/gpu',
        'MAPRISMA_SCAN_PROC': '${home.path}/proc',
        'MAPRISMA_CORE_WORKER': '${home.path}/worker',
        'ANTHROPIC_API_KEY': 'fixture',
      },
      migrate: false,
    );
    addTearDown(service.dispose);
    final task =
        service.smartRoute('map.smart_ask', {
              'column': 'providers',
              'command': 'claude',
              'request': 'Configure this provider',
            })['task']
            as String;
    for (var i = 0; i < 500; i++) {
      if (service.tasks.status(task)['state'] != 'running') break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(service.tasks.status(task)['state'], 'done');
    final body =
        jsonDecode(File('${home.path}/captured.json').readAsStringSync())
            as Map;
    final models =
        (body['providers'] as List).cast<Map>().firstWhere(
              (p) => p['key'] == 'llamacpp',
            )['models']
            as List;
    expect(models, hasLength(40));
    expect(models.every((m) => '$m'.startsWith('chat-')), isTrue);
  });

  for (final key in ['llamacpp', 'lmstudio']) {
    for (final gpu in [false, true]) {
      test(
        '$key control refuses a connected running agent with ${gpu ? 'idle GPU' : 'CPU only'}',
        () async {
          final home = Directory.systemTemp.createTempSync(
            'config-agent-guard',
          );
          addTearDown(() => home.deleteSync(recursive: true));
          void write(String name, String value) {
            final f = File('${home.path}/$name');
            f.parent.createSync(recursive: true);
            f.writeAsStringSync(value);
          }

          final provider = key == 'llamacpp' ? 'llama-local' : 'lmstudio-local';
          write(
            '.pi/agent/models.json',
            jsonEncode({
              'providers': {
                provider: {
                  'baseUrl': 'http://127.0.0.1:8080/v1',
                  'models': [
                    {'id': 'model'},
                  ],
                },
              },
            }),
          );
          write(
            '.pi/agent/settings.json',
            jsonEncode({'defaultProvider': provider, 'defaultModel': 'model'}),
          );
          write('proc/9999999/comm', 'pi\n');
          write('proc/9999999/cmdline', '/usr/bin/pi\u0000');
          if (gpu) {
            write('gpu/card0/device/mem_info_vram_total', '${8 * gib}');
            write('gpu/card0/device/mem_info_vram_used', '0');
            write('gpu/card0/device/gpu_busy_percent', '0');
          }
          final files = ScanFiles(
            AppIdentity(
              environment: {
                'HOME': home.path,
                'PATH': '',
                'MAPRISMA_SCAN_PROC': '${home.path}/proc',
                'MAPRISMA_SCAN_GPU': '${home.path}/gpu',
              },
            ),
          );
          final ops = ProviderOps(files, ProviderScans(files));
          final rt = RuntimeRecord(key, key)
            ..installed = true
            ..service = 'fixture'
            ..models = ['model'];
          final calls = <String>[];
          Future<(bool, String)> effect(String name) async {
            calls.add(name);
            return (true, '');
          }

          Future<Map<String, dynamic>> control() => configControl(
            ops,
            key == 'llamacpp' ? 'providers.restart' : 'providers.reload_model',
            {'key': key, if (key != 'llamacpp') 'model': 'model'},
            runtime: (_) => rt,
            stop: (_) => effect('stop'),
            start: (_) => effect('start'),
            unload: (_, _) => effect('unload'),
            load: (_, _) => effect('load'),
          );
          await expectLater(control(), throwsFormatException);
          expect(calls, isEmpty);
          Directory('${home.path}/proc/9999999').deleteSync(recursive: true);
          await control();
          expect(
            calls,
            key == 'llamacpp' ? ['stop', 'start'] : ['unload', 'load'],
          );
        },
      );
    }
  }

  test(
    'system Ollama without an app env file does not report a broken config',
    () async {
      final home = Directory.systemTemp.createTempSync('system-ollama-config');
      addTearDown(() => home.deleteSync(recursive: true));
      final files = ScanFiles(
        AppIdentity(environment: {'HOME': home.path, 'PATH': ''}),
      );
      final store = ProviderConfigFiles(files, ConfigFiles(Posix(), home.path));
      final rt = RuntimeRecord('ollama', 'Ollama')
        ..installed = true
        ..models = ['model'];
      final facts = await store.collect(
        rt,
        hardware: Map<String, dynamic>.from(configFixture()['hardware']),
        measurements: {},
      );
      expect(facts['writable'], false);
      expect(
        facts['notes'],
        isNot(contains('Some model settings could not be read')),
      );
      expect(
        facts['notes'],
        isNot(contains('Configuration file is unavailable')),
      );
      expect(
        File('${home.path}/.config/ollama/server.env').existsSync(),
        false,
      );
    },
  );

  test('empty research argv is not offered by either helper catalog', () {
    final home = Directory.systemTemp.createTempSync('config-empty-research');
    addTearDown(() => home.deleteSync(recursive: true));
    final helper = File('${home.path}/claude')
      ..writeAsStringSync('#!/bin/sh\necho 1.0\n');
    Process.runSync('chmod', ['+x', helper.path]);
    final service = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': home.path,
        'MAPRISMA_DESKTOP': 'generic',
        'ANTHROPIC_API_KEY': 'fixture',
      },
      migrate: false,
    );
    addTearDown(service.dispose);
    final original = builtinAdapters().firstWhere((a) => a.command == 'claude');
    final adapter = Adapter({
      ...original.facts,
      'research': {...original.table('research')},
    });
    adapter.table('research')['argv'] = <String>[];
    service.addons.adapters = [adapter];
    expect(service.smartHelpers().any((h) => h['web_search'] == true), false);
    expect(service.configHelpers().any((h) => h['web_search'] == true), false);
    service.configCache.keep('llamacpp', configFixture());
    expect(
      () => service.configRoute('models.config_ask', {
        'key': 'llamacpp',
        'model': 'model',
        'command': 'claude',
        'web_search': true,
      }),
      throwsFormatException,
    );
  });

  test(
    'empty research argv refuses config research before collection or a second call',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'config-worker-empty-research',
      );
      addTearDown(() => home.deleteSync(recursive: true));
      final helper = File('${home.path}/claude')
        ..writeAsStringSync('''#!/bin/sh
cat > "\$HOME/prompt"
echo call >> "\$HOME/calls"
echo '{"action":"provider_config","provider":"llamacpp"}'
''');
      Process.runSync('chmod', ['+x', helper.path]);
      final original = builtinAdapters().firstWhere(
        (a) => a.command == 'claude',
      );
      final adapter = Adapter({
        ...original.facts,
        'research': {...original.table('research')},
      });
      adapter.table('research')['argv'] = <String>[];
      var collected = 0;
      final answer = await smartAsk(
        {
          'column': 'providers',
          'command': 'claude',
          'request': 'Configure it',
          'web_search': true,
          'providers': [
            {
              'key': 'llamacpp',
              'name': 'Local',
              'configurable': true,
              'models': ['model'],
              'config_scope': 'default',
            },
          ],
          'action_rules': [
            {
              'effect': 'allow',
              'action': '*',
              'category': '*',
              'item': '*',
              'agent': '*',
            },
          ],
        },
        adapter,
        {'HOME': home.path, 'PATH': '${home.path}:/usr/bin:/bin'},
        home.path,
        'test',
        configFacts: (key, model, profile) async {
          collected++;
          return {...configFixture(), 'model': 'model'};
        },
      );
      expect(answer['code'], 'no_helper');
      expect(collected, 0);
      expect(File('${home.path}/calls').readAsLinesSync(), hasLength(1));
    },
  );

  test('empty non-global model decisions select the default model', () async {
    for (final key in ['llamacpp', 'jan']) {
      var calls = 0, collected = 0;
      String? requested = 'not-omitted';
      final f = configFixture(key: key);
      final contextId =
          configSchema(key).firstWhere((s) => s['role'] == 'context')['id']
              as String;
      final answer = await smartProviders(
        {
          'request': 'Configure it',
          'providers': [
            {
              'key': key,
              'name': 'Local',
              'configurable': true,
              'models': ['model'],
              'config_scope': key == 'jan' ? 'per_model' : 'default',
            },
          ],
          'action_rules': [
            {
              'effect': 'allow',
              'action': '*',
              'category': '*',
              'item': '*',
              'agent': '*',
            },
          ],
        },
        (prompt) async {
          calls++;
          return jsonEncode(
            calls == 1
                ? {'action': 'provider_config', 'provider': key, 'model': ''}
                : {
                    'summary': 'Config',
                    'values': {contextId: 8192},
                  },
          );
        },
        configFacts: (key, model, profile) async {
          collected++;
          requested = model;
          return {...f, 'model': 'model'};
        },
      );
      expect(answer['status'], 'proposal');
      expect(calls, 2);
      expect(collected, 1);
      expect(requested, isNull);
    }
  });

  test(
    'partial offload rejects impossible GPU memory but fitting partial only warns',
    () {
      final facts = configFixture(
        vram: 8 * gib,
        available: 8 * gib,
        weights: 10 * gib,
      );
      final math = ConfigMath(facts, 'model');
      final impossible = math.validate({'gpu-layers': 31, 'ctx-size': 131072});
      expect(impossible['fit']['basis'], 'vram');
      expect(impossible['errors'], isNotEmpty);
      final fitting = math.validate({'gpu-layers': 8, 'ctx-size': 8192});
      expect(fitting['errors'], isEmpty);
      expect(
        (fitting['warnings'] as List).any(
          (w) => w['text'] == 'Partial GPU offload can be slower',
        ),
        isTrue,
      );
    },
  );

  test('b12078 GPU KV excludes the output layer and CPU repeating layers', () {
    final facts = configFixture()..['version'] = 'b12078';
    final math = ConfigMath(facts, 'model');
    expect(math.fit({'gpu-layers': 1, 'ctx-size': 8192})['kv'], 0);
    final full = math.fit({'gpu-layers': 'all', 'ctx-size': 8192})['kv'] as int;
    expect(math.fit({'gpu-layers': 5, 'ctx-size': 8192})['kv'], full * 4 ~/ 32);
    // The last four repeating layers have a different cache shape, including SWA.
    final meta =
        ((facts['models'] as List).single['meta'] as Map<String, dynamic>);
    meta['llama.attention.head_count_kv'] = [
      for (var i = 0; i < 32; i++) i >= 28 ? 16 : 2,
    ];
    meta['llama.attention.sliding_window'] = 4096;
    meta['llama.attention.sliding_window_pattern'] = 4;
    final gpuMeta = <String, dynamic>{
      ...meta,
      'llama.attention.head_count_kv': [
        for (var i = 0; i < 32; i++) i >= 28 ? 16 : 0,
      ],
    };
    final (per, fixed) = kvLayout(gpuMeta, 'f16');
    expect(
      math.fit({'gpu-layers': 5, 'ctx-size': 8192})['kv'],
      fixed + 8192 * per,
    );
  });

  test(
    'known resident GPU cache alone can make a partial offload impossible',
    () {
      final facts = configFixture(
        vram: 8 * gib,
        available: 8 * gib,
        weights: 6 * gib,
      )..['version'] = 'b12078';
      final math = ConfigMath(facts, 'model');
      final result = math.validate({'gpu-layers': 31, 'ctx-size': 32768});
      expect(
        result['fit']['weights'] + result['fit']['reserve'],
        lessThan(8 * gib),
      );
      expect(result['fit']['total'], greaterThan(8 * gib));
      expect(result['errors'], isNotEmpty);
      final fits = math.validate({'gpu-layers': 8, 'ctx-size': 8192});
      expect(fits['errors'], isEmpty);
      expect(fits['warnings'], isNotEmpty);
    },
  );

  test('unverified partial cache placement is an explicit upper bound', () {
    final facts = configFixture(
      vram: 8 * gib,
      available: 8 * gib,
      weights: 6 * gib,
    )..['version'] = 'unknown';
    final result = ConfigMath(
      facts,
      'model',
    ).validate({'gpu-layers': 8, 'ctx-size': 131072});
    expect(result['fit']['total'], greaterThan(8 * gib));
    expect(result['errors'], isEmpty);
    expect(
      (result['warnings'] as List).any(
        (w) => '${w['text']}'.contains('upper bound'),
      ),
      true,
    );
  });

  for (final profile in configProfiles) {
    test('vLLM $profile recommendation stays within its GPU budget', () {
      final facts = configFixture(
        key: 'vllm',
        vram: 8 * gib,
        available: 7 * gib,
        weights: 2 * gib,
      );
      final math = ConfigMath(facts, 'model');
      final result = math.recommend(profile);
      expect(result['fit']['basis'], 'vram');
      expect(
        result['fit']['total'],
        lessThanOrEqualTo(result['fit']['available']),
      );
      expect(math.validate(result['values'])['errors'], isEmpty);
    });
  }

  test('vLLM without a GPU never claims a CPU-only fit', () {
    final facts = configFixture(key: 'vllm', vram: 0, available: 0);
    final math = ConfigMath(facts, 'model');
    final result = math.recommend('balanced');
    expect(result['fit']['basis'], 'vram');
    expect(math.validate(result['values'])['errors'], isNotEmpty);
  });

  test('vLLM never budgets an oversized GPU model from CPU RAM', () {
    final facts = configFixture(
      key: 'vllm',
      vram: 8 * gib,
      available: 8 * gib,
      weights: 10 * gib,
    );
    final math = ConfigMath(facts, 'model'),
        result = math.recommend('balanced');
    final values = result['values'] as Map;
    expect(result['fit']['basis'], 'vram');
    expect(
      result['fit']['available'],
      lessThanOrEqualTo(8 * gib * (values['gpu-memory-utilization'] as num)),
    );
    expect(values['max-model-len'], 4096);
    expect(
      (result['recommended'] as List).any(
        (r) => '${r['reason']}'.toLowerCase().contains('too large'),
      ),
      isTrue,
    );
    expect(math.validate(values)['errors'], isNotEmpty);
  });

  test(
    'recommended utilization and offload fractions round down to hundredths',
    () {
      final vllm = ConfigMath(
        configFixture(key: 'vllm', vram: 33 * gib, available: 23 * gib),
        'model',
      ).recommend('balanced');
      expect(vllm['values']['gpu-memory-utilization'], 0.69);
      final studio = ConfigMath(
        configFixture(
          key: 'lmstudio',
          vram: 8 * gib,
          available: 8 * gib,
          weights: 7 * gib,
        ),
        'model',
      ).recommend('balanced');
      final ratio = studio['values']['gpuOffload'] as num;
      expect(ratio, lessThan(1));
      expect(ratio, closeTo((ratio * 100).round() / 100, 1e-12));
      expect(jsonEncode(vllm['values']), isNot(contains('0.696969')));
    },
  );

  test(
    'INI insertion separates a final header, and empty deletion stays empty',
    () {
      expect(
        ContextReader.iniText('[model]', 'model', 'ctx-size', '8192'),
        '[model]\nctx-size = 8192\n',
      );
      expect(
        ContextReader.iniText('[model] # keep', 'model', 'ctx-size', '8192'),
        '[model] # keep\nctx-size = 8192\n',
      );
      expect(ContextReader.iniText('', 'model', 'ctx-size', null), '');
    },
  );

  test(
    'file writers never return launch advice when their files are unwritable',
    () {
      final home = Directory.systemTemp.createTempSync('config-independent');
      addTearDown(() => home.deleteSync(recursive: true));
      final files = ScanFiles(
        AppIdentity(environment: {'HOME': home.path, 'PATH': ''}),
      );
      final store = ProviderConfigFiles(files, ConfigFiles(Posix(), home.path));
      for (final key in ['llamacpp', 'jan', 'lmstudio', 'koboldcpp']) {
        expect(
          store.snippet(configFixture(key: key), 'model', const {}),
          isNull,
          reason: key,
        );
      }
    },
  );
}
