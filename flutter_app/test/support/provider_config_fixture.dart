import 'package:maprisma_core/src/provider_config.dart';

Map<String, dynamic> configurationFixture(
  String key, {
  String model = '*',
  String profile = 'balanced',
}) {
  final schema = configSchema(key);
  if (schema.first['scope'] == 'global') model = '';
  final current = <String, dynamic>{
    for (final s in schema) '${s['id']}': s['default'],
  };
  final facts = <String, dynamic>{
    'key': key,
    'runtime':
        {'llamacpp': 'llama.cpp', 'ollama': 'Ollama', 'vllm': 'vLLM'}[key] ??
        key,
    'schema': schema,
    'hardware': {
      'gpu': 'AMD Radeon RX 7900 XTX',
      'vendor': 'amd',
      'vram_total': 24 << 30,
      'vram_available': 23 << 30,
      'ram_total': 64 << 30,
      'ram_available': 48 << 30,
      'physical_cores': 8,
      'logical_cores': 16,
      'gpu_count': 1,
      'stacks': ['Vulkan', 'ROCm'],
    },
    'models': [
      {
        'name': 'Qwen 7B Q4',
        'size': 4 << 30,
        'meta': {
          'general.architecture': 'llama',
          'llama.context_length': 131072,
          'llama.block_count': 32,
          'llama.embedding_length': 4096,
          'llama.attention.head_count': 32,
          'llama.attention.head_count_kv': 8,
        },
      },
    ],
    'defaults': current,
    'settings': {'*': current, 'Qwen 7B Q4': current},
    'overrides': model == '*' ? <String>[] : ['ctx-size'],
    'build': 'vulkan',
    'build_mark': 'fixture',
    'measurements': {},
    'writable': key != 'vllm',
    'can_control': true,
    'running': true,
    'can_reload': false,
    'model': model,
    'profile': profile,
    'scope_models': schema.first['scope'] == 'global'
        ? <String>[]
        : ['*', 'Qwen 7B Q4'],
    'helpers': [
      {
        'command': 'claude',
        'name': 'Claude Code',
        'local': false,
        'web_search': true,
      },
      {
        'command': 'local-helper',
        'name': 'Local helper',
        'local': true,
        'web_search': false,
      },
    ],
    'restart': schema.first['restart'],
    'untuned': [],
    'notes': [],
    if (key == 'vllm')
      'snippet':
          'vllm serve <model> --max-model-len 32768 --gpu-memory-utilization 0.9',
    if (key == 'vllm')
      'read_only_reason': 'This provider offers configuration advice',
  };
  final rec = ConfigMath(facts, model).recommend(profile);
  return {
    ...facts,
    'current': current,
    'recommended': rec['recommended'],
    'fit': rec['fit'],
  };
}
