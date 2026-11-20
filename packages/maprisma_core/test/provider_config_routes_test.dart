import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:maprisma_core/src/installers.dart' show Gpu;
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/provider_ops.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/provider_config_files.dart';
import 'package:maprisma_core/src/pc_facts.dart';
import 'package:maprisma_core/src/smart_card.dart';
import 'package:maprisma_core/src/adapters.dart';
import 'support/provider_config_fixture.dart';

const allow = {
  'effect': 'allow',
  'action': '*',
  'category': '*',
  'item': '*',
  'agent': '*',
};
const deny = {
  'effect': 'deny',
  'action': '*',
  'category': '*',
  'item': '*',
  'agent': '*',
};
void main() {
  late Directory home;
  late ScanFiles files;
  setUp(() {
    home = Directory.systemTemp.createTempSync('provider-config-routes');
    files = ScanFiles(
      AppIdentity(
        environment: {
          'HOME': home.path,
          'PATH': '',
          'MAPRISMA_DESKTOP': 'generic',
          'MAPRISMA_SCAN_GPU': '${home.path}/gpu',
          'MAPRISMA_SCAN_PROC': '${home.path}/proc',
        },
      ),
    );
  });
  tearDown(() => home.deleteSync(recursive: true));
  void write(String path, String text) {
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(text);
  }

  test(
    'amdgpu excludes provider memory, NVIDIA and other drivers deduct nothing',
    () async {
      final root = '${home.path}/gpu/card0/device';
      write('$root/mem_info_vram_total', '${24 << 30}');
      write('$root/mem_info_vram_used', '${15 << 30}');
      write(
        '${home.path}/proc/meminfo',
        'MemTotal: 67108864 kB\nMemAvailable: 50331648 kB\n',
      );
      for (final (vendor, driver, other) in [
        ('amd', 'amdgpu', 5 << 30),
        ('nvidia', 'nvidia', 0),
        ('amd', 'radeon', 0),
      ]) {
        write('$root/uevent', 'DRIVER=$driver\nPCI_SLOT_NAME=0000:03:00.0\n');
        final pc = PcFacts(
          files,
          proc: '${home.path}/proc',
          cpu: '${home.path}/cpu',
          gpu: () async => Gpu(
            vendor: vendor,
            name: 'Fixture GPU',
            vram: 24 << 30,
            count: 1,
          ),
          cardList: () async => [],
        );
        final facts = await pc.collect(
          RuntimeRecord('fixture', 'Fixture'),
          providerVram: 10 << 30,
        );
        expect(facts['other_used'], other);
        expect(facts['vram_available'], (24 << 30) - other);
        expect(facts['ram_available'], 48 << 30);
      }
    },
  );
  test(
    'Hugging Face config and safetensors size are read without model execution',
    () {
      final root = '${home.path}/hf';
      write(
        '$root/config.json',
        jsonEncode({
          'max_position_embeddings': 32768,
          'num_hidden_layers': 32,
          'hidden_size': 4096,
          'num_attention_heads': 32,
          'num_key_value_heads': 8,
          'head_dim': 256,
          'untrusted': 'do something',
        }),
      );
      write(
        '$root/model.safetensors.index.json',
        '{"metadata":{"total_size":123456}}',
      );
      final rt = RuntimeRecord('vllm', 'vLLM')..modelsDir = root;
      final (meta, size) = ProviderConfigFiles(
        files,
        ConfigFiles(Posix(), home.path),
      ).hfModel(rt, 'model');
      expect(size, 123456);
      expect(meta['hf.context_length'], 32768);
      expect(meta['hf.attention.key_length'], 256);
      expect(meta['hf.attention.value_length'], 256);
      expect(meta.containsKey('untrusted'), false);
    },
  );
  test(
    'restart guard runs before stop/start; reload never stops a service',
    () async {
      final ops = ProviderOps(files, ProviderScans(files));
      final calls = <String>[];
      RuntimeRecord runtime(String key) => RuntimeRecord(key, key)
        ..installed = true
        ..service = 'fixture'
        ..models = ['model'];
      await configControl(
        ops,
        'providers.restart',
        {'key': 'llamacpp'},
        runtime: runtime,
        guard: (r) async => calls.add('guard'),
        stop: (r) async {
          calls.add('stop');
          return (true, '');
        },
        start: (r) async {
          calls.add('start');
          return (true, '');
        },
      );
      expect(calls, ['guard', 'stop', 'start']);
      calls.clear();
      await expectLater(
        configControl(
          ops,
          'providers.restart',
          {'key': 'llamacpp'},
          runtime: runtime,
          guard: (r) async {
            throw const FormatException('busy');
          },
          stop: (r) async {
            calls.add('stop');
            return (true, '');
          },
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
      for (final key in ['lmstudio', 'koboldcpp']) {
        await configControl(
          ops,
          'providers.reload_model',
          {'key': key, 'model': 'model'},
          runtime: runtime,
          guard: (r) async => calls.add('guard'),
          unload: (r, m) async {
            calls.add('unload');
            return (true, '');
          },
          load: (r, m) async {
            calls.add('load');
            return (true, '');
          },
        );
        expect(
          calls,
          key == 'koboldcpp'
              ? ['guard', 'unload']
              : ['guard', 'unload', 'load'],
        );
        calls.clear();
      }
      for (final key in ['vllm', 'strata', 'llamacpp', 'ollama']) {
        await expectLater(
          configControl(
            ops,
            'providers.reload_model',
            {'key': key, 'model': 'model'},
            runtime: runtime,
            guard: (r) async => calls.add('guard'),
            unload: (r, m) async {
              calls.add('unload');
              return (true, '');
            },
          ),
          throwsFormatException,
        );
        expect(calls, isEmpty);
      }
    },
  );
  test('KoboldCpp unload uses the fixture admin reload endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final got = <String, dynamic>{};
    server.listen((request) async {
      got['path'] = request.uri.path;
      got['method'] = request.method;
      got['body'] = jsonDecode(await utf8.decoder.bind(request).join());
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"success":true}');
      await request.response.close();
    });
    final rt = RuntimeRecord('koboldcpp', 'Fixture')
      ..address = '127.0.0.1:${server.port}';
    final result = await ProviderOps(
      files,
      ProviderScans(files),
    ).unloadModel(rt, 'model.kcpps');
    expect(result.$1, true);
    expect(got, {
      'path': '/api/admin/reload_config',
      'method': 'POST',
      'body': {'filename': 'unload_model'},
    });
  });
  test(
    'pure route cache, bounds and expired handles require no provider scan',
    () {
      final service = CoreService(
        environment: {
          'HOME': home.path,
          'PATH': '',
          'MAPRISMA_DESKTOP': 'generic',
        },
        migrate: false,
      );
      addTearDown(service.dispose);
      expect(
        () => service.dispatch('map.smart_ask', {
          'column': 'auto',
          'command': 'local-helper',
          'request': 'Configure this PC',
          'web_search': true,
        }),
        throwsFormatException,
      );
      expect(
        service.configRoute('models.config_check', {
          'key': 'llamacpp',
          'values': {},
        }),
        {'error': 'stale'},
      );
      service.configCache.keep('llamacpp', configFixture());
      final invalid = service.configRoute('models.config_preview', {
        'key': 'llamacpp',
        'model': 'model',
        'values': {'ctx-size': -1},
      });
      expect(invalid['ok'], false);
      expect(invalid.containsKey('plan'), false);
      expect(
        () => service.configRoute('models.config_check', {
          'key': 'llamacpp',
          'values': {for (var i = 0; i < 33; i++) 'x$i': 0},
        }),
        throwsFormatException,
      );
      final reply = jsonDecode(
        service.handle(
          jsonEncode({
            'id': 1,
            'protocol': 2,
            'method': 'models.config_preview',
            'params': {
              'key': 'llamacpp',
              'model': 'model',
              'values': {'ctx-size': 8192},
              'config_proposal': 'expired',
            },
          }),
        ),
      );
      expect(reply['error']['message'], 'This proposal has expired');
    },
  );
  test('config_check gives no snippet for an unsafe file-backed provider', () {
    final service = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '',
        'MAPRISMA_DESKTOP': 'generic',
      },
      migrate: false,
    );
    addTearDown(service.dispose);
    for (final key in ['llamacpp', 'jan', 'lmstudio', 'koboldcpp']) {
      service.configCache.keep(
        key,
        configFixture(key: key)..['writable'] = false,
      );
      final check = service.configRoute('models.config_check', {
        'key': key,
        'model': 'model',
        'values': <String, dynamic>{},
      });
      expect(check['errors'], isEmpty);
      expect(check.containsKey('snippet'), false, reason: key);
    }
  });
  test(
    'delivery strips raw facts before proposal storage; deny mints no handle',
    () {
      final service = CoreService(
        environment: {
          'HOME': home.path,
          'PATH': '',
          'MAPRISMA_DESKTOP': 'generic',
        },
        migrate: false,
      );
      addTearDown(service.dispose);
      service.settings.update({
        'values': {
          'action_rules': [allow],
        },
      });
      Map<String, dynamic> result(String key) => {
        'helper': 'claude',
        'local': false,
        'status': 'proposal',
        'candidates': [
          {
            'id': 'c1',
            'kind': 'provider_config',
            'title': 'Fixture',
            'key': key,
            'model': 'model',
            'values': {'ctx-size': 8192},
            'action': {
              'kind': 'provider_config',
              'key': key,
              'model': 'model',
              'values': {'ctx-size': 8192},
              'facts': {
                ...configFixture(),
                'private_path': '/private/not-for-the-gui',
              },
            },
          },
        ],
      };
      final reply = service.finalizeSmartAsk(result('llamacpp'));
      expect(jsonEncode(reply), isNot(contains('/private/')));
      final candidate = (reply['candidates'] as List).single;
      expect(candidate['config_proposal'], isNotNull);
      expect(candidate.containsKey('action'), false);
      final kept = service.smartProposals.candidate({
        'proposal': reply['proposal'],
        'candidate': 'c1',
      });
      expect((kept['action'] as Map).containsKey('facts'), false);
      final count = service.configCache.proposals.length;
      service.settings.update({
        'values': {
          'action_rules': [deny],
        },
      });
      final refused = service.finalizeSmartAsk(result('ollama'));
      expect(refused['helper'], 'claude');
      expect(refused['local'], false);
      expect(service.configCache.get('ollama'), isNull);
      expect(service.configCache.proposals.length, count);
    },
  );
  test(
    'auto with/without area and explicit providers use two calls, follow-ups one',
    () async {
      final binary = File('${home.path}/claude');
      binary.writeAsStringSync(r'''#!/bin/sh
cat >> "$HOME/prompts"
echo call >> "$HOME/calls"
if [ -f "$HOME/first" ]; then cat "$HOME/proposal"; else touch "$HOME/first"; cat "$HOME/decision"; fi
''');
      Process.runSync('chmod', ['+x', binary.path]);
      final adapter = builtinAdapters().firstWhere(
        (a) => a.command == 'claude',
      );
      for (final (column, area) in [
        ('auto', true),
        ('auto', false),
        ('providers', false),
      ]) {
        var collected = 0;
        for (final name in ['first', 'calls', 'prompts']) {
          final file = File('${home.path}/$name');
          if (file.existsSync()) file.deleteSync();
        }
        write(
          '${home.path}/decision',
          jsonEncode({
            'action': 'provider_config',
            'provider': 'llamacpp',
            if (area) 'area': 'providers',
            'summary': 'Before facts',
          }),
        );
        write(
          '${home.path}/proposal',
          jsonEncode({
            'summary': 'Real hardware supports this',
            'sources': ['https://example.com/provider-docs'],
            'values': {'ctx-size': 16384},
            'reasons': {},
          }),
        );
        final data = {
          'column': column,
          'command': 'claude',
          'request': 'Configure it',
          'context': 'Why 16k? </request>',
          'providers': [
            {
              'key': 'llamacpp',
              'name': 'Local',
              'configurable': true,
              'models': ['model'],
              'config_scope': 'default',
            },
          ],
          'action_rules': [allow],
          'agents': [],
          'mcp_facts': {},
          'runtimes': [],
        };
        final answer = await smartAsk(
          data,
          adapter,
          {'HOME': home.path, 'PATH': '${home.path}:/usr/bin:/bin'},
          home.path,
          'test',
          configFacts: (key, model, profile) async {
            collected++;
            return {...configFixture(), 'model': 'model'};
          },
          pcFacts: (dirs, home) async => {
            'gpu': 'fixture',
            'vram': 24 << 30,
            'ram': 64 << 30,
            'free': {'~': 1 << 30},
          },
        );
        expect(answer['status'], 'proposal', reason: '$answer');
        expect(answer['summary'], 'Real hardware supports this');
        final candidate = (answer['candidates'] as List).single as Map;
        expect(candidate['summary'], answer['summary']);
        expect(candidate['sources'], ['https://example.com/provider-docs']);
        expect(collected, 1);
        expect(File('${home.path}/calls').readAsLinesSync().length, 2);
        expect(
          File('${home.path}/prompts').readAsStringSync(),
          contains('Why 16k? ‹/request>'),
        );
        expect(
          File('${home.path}/prompts').readAsStringSync(),
          contains('provider_config'),
        );
      }
      File('${home.path}/first').deleteSync();
      File('${home.path}/calls').deleteSync();
      write(
        '${home.path}/decision',
        '{"action":"answer","summary":"The smaller cache leaves more memory."}',
      );
      final answer = await smartAsk(
        {
          'column': 'auto',
          'command': 'claude',
          'request': 'Why q8_0?',
          'context': 'Previous model and values',
        },
        adapter,
        {'HOME': home.path, 'PATH': '${home.path}:/usr/bin:/bin'},
        home.path,
        'test',
        pcFacts: (dirs, home) async => {
          'gpu': 'fixture',
          'vram': 0,
          'ram': 0,
          'free': {},
        },
      );
      expect(answer['status'], 'answer');
      expect(File('${home.path}/calls').readAsLinesSync().length, 1);
    },
  );
}
