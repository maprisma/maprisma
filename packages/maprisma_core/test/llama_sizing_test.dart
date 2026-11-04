import 'dart:io';
import 'package:maprisma_core/src/connect_apply.dart';
import 'package:maprisma_core/src/context.dart';
import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/llm_tuning.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/scan_files.dart';
import 'package:test/test.dart';

/// Task 029: a context the app works out for a llama.cpp model (connecting
/// it to an agent) counts only the model's own section, and brings a q8_0
/// KV cache and flash attention where nothing is set (context_ctl alike).
void main() {
  late Directory home;
  late ContextReader reader;
  setUp(() {
    home = Directory.systemTemp.createTempSync('llama-sizing-');
    Directory('${home.path}/.config/llama.cpp').createSync(recursive: true);
    reader = ContextReader(
      ScanFiles(AppIdentity(environment: {'HOME': home.path})),
      ConfigFiles(Posix(), home.path),
    );
  });
  tearDown(() => home.deleteSync(recursive: true));
  void ini(String text) => File(reader.modelsIni).writeAsStringSync(text);

  test('the catch-all context is not the model\'s own', () {
    ini('version = 1\n\n[*]\nctx-size = 8192\n\n[Set]\nctx-size = 32768\n');
    expect(reader.llamaOwnContext('Qwen'), 0);
    expect(reader.llamaOwnContext('Set'), 32768);
    // The readers that show what a model runs with still count "[*]".
    expect(reader.llamaSettings('Qwen').$1, 8192);
  });

  test('sized for the cache set, else q8_0', () {
    ini('[*]\nctx-size = 8192\n');
    expect(reader.llamaAutoCache('Qwen'), 'q8_0');
    ini('[*]\ncache-type-k = q4_0\n');
    expect(reader.llamaAutoCache('Qwen'), 'q4_0');
    ini('[*]\ncache-type-k = q4_0\n\n[Qwen]\ncache-type-k = f16\n');
    expect(reader.llamaAutoCache('Qwen'), 'f16');
  });

  test('q8_0 and flash attention only where nothing is set', () {
    final fresh = ContextReader.llamaSizedText(
      'version = 1\n\n[*]\nctx-size = 8192\n',
      'Qwen',
      65536,
    );
    final section = fresh.split('[Qwen]')[1];
    for (final line in [
      'ctx-size = 65536',
      'cache-type-k = q8_0',
      'cache-type-v = q8_0',
      'flash-attn = on',
    ]) {
      expect(section, contains(line));
    }
    expect(fresh, contains('[*]\nctx-size = 8192'));
    final chosen = ContextReader.llamaSizedText(
      '[*]\ncache-type-k = q4_0\ncache-type-v = q4_0\nflash-attn = off\n',
      'Qwen',
      65536,
    );
    expect(chosen.split('[Qwen]')[1].trim(), 'ctx-size = 65536');
  });

  test(
    'Set to … brings q8_0 and flash attention like a worked-out context',
    () {
      ini('version = 1\n\n[*]\nctx-size = 8192\n');
      final change = LlmTuning(
        reader,
        home.path,
      ).contextChanges('llamacpp', 'Qwen', 65536).single;
      final section = change.next.split('[Qwen]')[1];
      for (final line in [
        'ctx-size = 65536',
        'cache-type-k = q8_0',
        'cache-type-v = q8_0',
        'flash-attn = on',
      ]) {
        expect(section, contains(line));
      }
    },
  );
}
