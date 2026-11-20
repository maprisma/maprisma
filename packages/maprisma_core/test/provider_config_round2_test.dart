import 'dart:io';

import 'package:maprisma_core/src/context.dart' show gib;
import 'package:maprisma_core/src/core.dart';
import 'package:maprisma_core/src/provider_config.dart';
import 'package:test/test.dart';

import 'support/provider_config_fixture.dart';

const capacityMessage = 'Configuration exceeds this PC’s memory capacity';
const availableMessage = 'Configuration exceeds currently available memory';

Map<String, dynamic> partialFacts({
  bool verified = true,
  int weights = 4 * gib,
  int ram = 16 * gib,
  int ramAvailable = 16 * gib,
  int vramAvailable = 8 * gib,
  bool swa = false,
}) {
  final facts = configFixture(
    vram: 8 * gib,
    available: vramAvailable,
    weights: weights,
    layers: 64,
    swa: swa,
  )..['version'] = verified ? 'b12078' : 'unknown';
  facts['hardware'] = <String, dynamic>{
    ...facts['hardware'] as Map,
    'ram_total': ram,
    'ram_available': ramAvailable,
  };
  return facts;
}

void main() {
  test('the 20 GiB partial model fits the GPU but cannot fit 16 GiB RAM', () {
    final facts = partialFacts(weights: 20 * gib);
    final values = {
      'gpu-layers': 10,
      'ctx-size': 131072,
      'cache-type-k': 'q8_0',
      'cache-type-v': 'q8_0',
      'flash-attn': 'on',
    };
    final check = ConfigMath(facts, 'model').validate(values);
    expect(check['fit']['total'], lessThan(8 * gib));
    expect(check['errors'], contains(containsPair('text', capacityMessage)));
    expect(
      configAnswer(
        {'summary': 'Use partial offload', 'values': values},
        facts,
        'model',
      ),
      containsPair('code', 'bad_answer'),
    );
  });

  test('output-only GPU offload rejects the CPU cache above RAM', () {
    final facts = partialFacts(), math = ConfigMath(facts, 'model');
    final values = {'gpu-layers': 1, 'ctx-size': 131072};
    final check = math.validate(values), fit = check['fit'];
    expect(fit['basis'], 'vram');
    expect(fit['kv'], 0);
    expect(fit['total'], lessThan(8 * gib));
    expect(check['errors'], contains(containsPair('text', capacityMessage)));
    expect(
      configAnswer(
        {'summary': 'Use this context', 'values': values},
        facts,
        'model',
      ),
      containsPair('code', 'bad_answer'),
    );
  });

  test(
    'partial CPU weights above RAM are refused even with unverified cache',
    () {
      final facts = partialFacts(verified: false, weights: 20 * gib);
      final check = ConfigMath(
        facts,
        'model',
      ).validate({'gpu-layers': 10, 'ctx-size': 8192});
      expect(check['fit']['total'], lessThan(8 * gib));
      expect(check['errors'], contains(containsPair('text', capacityMessage)));
    },
  );

  test('unverified CPU cache cannot cause a false RAM capacity refusal', () {
    final facts = partialFacts(verified: false);
    final check = ConfigMath(
      facts,
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 131072});
    expect(check['fit']['total'], greaterThan(8 * gib));
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).any(
        (w) => '${w['text']}'.contains('upper bound'),
      ),
      true,
    );
  });

  test('partial CPU memory above available RAM warns without an error', () {
    final check = ConfigMath(
      partialFacts(ramAvailable: 8 * gib),
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 32768});
    expect(check['fit']['total'], lessThan(check['fit']['available']));
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).where((w) => w['text'] == availableMessage),
      hasLength(1),
    );
  });

  test('GPU and CPU available-memory warnings are not duplicated', () {
    final check = ConfigMath(
      partialFacts(ramAvailable: 8 * gib, vramAvailable: gib),
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 32768});
    expect(check['fit']['total'], greaterThan(check['fit']['available']));
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).where((w) => w['text'] == availableMessage),
      hasLength(1),
    );
  });

  test('zero available RAM warns for a partial offload', () {
    final check = ConfigMath(
      partialFacts(ramAvailable: 0),
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 8192});
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).where((w) => w['text'] == availableMessage),
      hasLength(1),
    );
  });

  test('unknown RAM facts do not claim an available-memory overcommit', () {
    final check = ConfigMath(
      partialFacts(ram: 0, ramAvailable: 0),
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 131072});
    expect(check['fit']['total'], lessThan(check['fit']['available']));
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).where((w) => w['text'] == availableMessage),
      isEmpty,
    );
  });

  test('CPU equality with RAM fits without adding the GPU reserve again', () {
    const weights = 65 * (1 << 20), cpuNeed = 2 * gib + 64 * (1 << 20);
    final facts = partialFacts(
      weights: weights,
      ram: cpuNeed,
      ramAvailable: cpuNeed,
    );
    final check = ConfigMath(
      facts,
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 8192});
    expect(check['fit']['weights'], 1 << 20);
    expect(check['errors'], isEmpty);
    expect(
      (check['warnings'] as List).where((w) => w['text'] == availableMessage),
      isEmpty,
    );
  });

  test('CPU cache capacity includes sliding-window fixed memory', () {
    final facts = partialFacts(
      swa: true,
      ram: 12 * gib,
      ramAvailable: 12 * gib,
    );
    final check = ConfigMath(
      facts,
      'model',
    ).validate({'gpu-layers': 1, 'ctx-size': 131072});
    expect(check['fit']['kv'], 0);
    expect(check['fit']['total'], lessThan(8 * gib));
    expect(check['errors'], contains(containsPair('text', capacityMessage)));
  });

  test('negative context already on disk uses the same zero clamp on CPU', () {
    const ram = gib - (32 << 10);
    final facts =
        partialFacts(
            weights: 65 * (1 << 20),
            swa: true,
            ram: ram,
            ramAvailable: ram,
          )
          ..['settings'] = <String, dynamic>{
            'model': {'gpu-layers': 1, 'ctx-size': -1},
          };
    final math = ConfigMath(facts, 'model');
    final check = math.validate({'threads': 4});
    // CPU weights (64 MiB) plus fixed SWA (960 MiB) require 1 GiB.
    // A raw context of -1 subtracts 64 KiB and slips below RAM by 32 KiB.
    expect(check['fit']['kv'], 0);
    expect(check['fit']['total'], lessThan(8 * gib));
    expect(check['errors'], contains(containsPair('text', capacityMessage)));
    expect(
      configAnswer(
        {
          'summary': 'Set threads',
          'values': {'threads': 4},
        },
        facts,
        'model',
      ),
      containsPair('code', 'bad_answer'),
    );
  });

  test(
    'config check and preview refuse CPU overcommit without provider operations',
    () {
      final home = Directory.systemTemp.createTempSync('config-round2-ram');
      addTearDown(() => home.deleteSync(recursive: true));
      final service = CoreService(
        environment: {
          'HOME': home.path,
          'PATH': '',
          'MAPRISMA_DESKTOP': 'generic',
          'MAPRISMA_SCAN_GPU': '${home.path}/gpu',
          'MAPRISMA_SCAN_PROC': '${home.path}/proc',
        },
        migrate: false,
      );
      addTearDown(service.dispose);
      service.configCache.keep('llamacpp', partialFacts());
      final params = {
        'key': 'llamacpp',
        'model': 'model',
        'values': {'gpu-layers': 1, 'ctx-size': 131072},
      };
      final check = service.configRoute('models.config_check', params);
      expect(check['errors'], contains(containsPair('text', capacityMessage)));
      final preview = service.configRoute('models.config_preview', params);
      expect(preview['ok'], false);
      expect(preview.containsKey('plan'), false);
      expect(preview['errors'], check['errors']);
    },
  );
}
