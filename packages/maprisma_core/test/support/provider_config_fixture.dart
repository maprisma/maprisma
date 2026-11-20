import 'dart:convert';
import 'dart:typed_data';
import 'package:maprisma_core/src/context.dart';
import 'package:maprisma_core/src/provider_config.dart';

List<int> configGguf(int trained) {
  final out = BytesBuilder();
  void u32(int n) => out.add(
    (ByteData(4)..setUint32(0, n, Endian.little)).buffer.asUint8List(),
  );
  void u64(int n) => out.add(
    (ByteData(8)..setUint64(0, n, Endian.little)).buffer.asUint8List(),
  );
  void str(String value) {
    final bytes = utf8.encode(value);
    u64(bytes.length);
    out.add(bytes);
  }

  final numbers = {
    'llama.context_length': trained,
    'llama.block_count': 32,
    'llama.embedding_length': 4096,
    'llama.attention.head_count': 32,
    'llama.attention.head_count_kv': 8,
  };
  out.add(ascii.encode('GGUF'));
  u32(3);
  u64(0);
  u64(numbers.length + 1);
  str('general.architecture');
  u32(8);
  str('llama');
  for (final e in numbers.entries) {
    str(e.key);
    u32(4);
    u32(e.value);
  }
  return out.toBytes();
}

Map<String, dynamic> configFixture({
  String key = 'llamacpp',
  int vram = 24 * gib,
  int available = 23 * gib,
  int weights = 4 * gib,
  int layers = 32,
  int trained = 131072,
  bool swa = false,
}) {
  final schema = configSchema(key);
  return {
    'key': key,
    'runtime': 'Fixture',
    'schema': schema,
    'hardware': {
      'gpu': 'Fixture GPU',
      'vendor': 'amd',
      'gpu_count': vram > 0 ? 1 : 0,
      'vram_total': vram,
      'vram_available': available,
      'ram_total': 64 * gib,
      'ram_available': 60 * gib,
      'physical_cores': 8,
      'logical_cores': 16,
    },
    'models': <Map<String, dynamic>>[
      {
        'name': 'model',
        'size': weights,
        'meta': {
          'general.architecture': 'llama',
          'llama.block_count': layers,
          'llama.context_length': trained,
          'llama.embedding_length': 4096,
          'llama.attention.head_count': 32,
          'llama.attention.head_count_kv': 8,
          if (swa) 'llama.attention.sliding_window': 4096,
          if (swa) 'llama.attention.sliding_window_pattern': 4,
        },
      },
    ],
    'settings': <String, dynamic>{},
    'defaults': {for (final s in schema) s['id']: s['default']},
    'measurements': <String, dynamic>{},
    'build_mark': 'build-1',
    'build': 'vulkan',
    'writable': true,
  };
}
