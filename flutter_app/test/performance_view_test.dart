import 'package:asterism/performance_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _facts(String key) => {
  'runtime': key == 'llamacpp' ? 'llama.cpp' : 'Ollama',
  'key': key,
  'gpu': 'AMD Radeon',
  'vram': 24 << 30,
  'stacks': ['ROCm', 'Vulkan'],
  'build': 'rocm',
  'builds': ['rocm', 'vulkan'],
  'devices': 'ROCm0: AMD Radeon RX',
  'settings': {
    '*': {'flash-attn': 'on'},
  },
  'tuning': {
    'flash-attn': ['on|off|auto', 'flash attention'],
    'threads': [r'[1-9]|[1-9]\d', 'CPU threads'],
  },
  'per_model': true,
  'models': [
    {
      'name': 'too-big',
      'size': 16 << 30,
      'context': 131072,
      'best': 65536,
      'trained': 262144,
      'per_token': 4096,
    },
    {
      'name': 'room',
      'size': 4 << 30,
      'context': 8192,
      'best': 32768,
      'trained': 32768,
      'per_token': 2048,
    },
    {
      'name': 'default',
      'size': 0,
      'context': 0,
      'best': 0,
      'trained': 0,
      'per_token': 0,
    },
  ],
  'loaded': [],
  'vram_used': 0,
};

void main() {
  Future<List<(String, String, String)>> pump(
    WidgetTester tester,
    String key,
  ) async {
    final changes = <(String, String, String)>[];
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PerformanceView(
            facts: _facts(key),
            tr: (k) => k,
            onChange: (s, k, v) => changes.add((s, k, v)),
            onClose: () {},
          ),
        ),
      ),
    );
    return changes;
  }

  testWidgets('build, stacks, memory and the context per model', (
    tester,
  ) async {
    final changes = await pump(tester, 'llamacpp');
    expect(find.text('ROCm'), findsOneWidget);
    expect(find.text('ROCm, Vulkan'), findsOneWidget);
    expect(find.text('24.0 GB'), findsOneWidget);
    expect(
      find.text(
        '16.0 GB · now {0} · fits {0} · trained for {0}'
            .replaceFirst('{0}', '128k')
            .replaceFirst('{0}', '64k')
            .replaceFirst('{0}', '256k'),
      ),
      findsOneWidget,
    );
    expect(find.text('its default'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    await tester.tap(find.text('Set to {0}'.replaceAll('{0}', '64k')));
    await tester.tap(find.text('Set to {0}'.replaceAll('{0}', '32k')));
    expect(changes, [
      ('too-big', 'ctx-size', '65536'),
      ('room', 'ctx-size', '32768'),
    ]);
  });

  testWidgets(
    'a setting with a list of values is chosen; Ollama has no Set to',
    (tester) async {
      final changes = await pump(tester, 'ollama');
      expect(find.textContaining('Set to'), findsNothing);
      expect(find.text('—'), findsOneWidget); // threads: a pattern, not set
      await tester.tap(find.text('on'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('auto').last);
      await tester.pumpAndSettle();
      expect(changes, [('*', 'flash-attn', 'auto')]);
    },
  );

  testWidgets('tips from an agent: asked, checked ones shown, applied', (
    tester,
  ) async {
    final changes = <(String, String, String)>[];
    final asked = <String>[];
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PerformanceView(
            facts: {
              ..._facts('llamacpp'),
              'helpers': [
                {'command': 'codex', 'name': 'Codex'},
                {'command': 'claude', 'name': 'Claude Code'},
              ],
            },
            tr: (k) => k,
            onChange: (s, k, v) => changes.add((s, k, v)),
            onClose: () {},
            onAsk: (command) async {
              asked.add(command);
              return {
                'summary': 'Two things.',
                'agent': command,
                'suggestions': [
                  {
                    'kind': 'setting',
                    'title': 'Quantize the cache',
                    'why': 'Half the memory.',
                    'model': 'room',
                    'key': 'cache-type-k',
                    'value': 'q8_0',
                  },
                  {
                    'kind': 'build',
                    'title': 'Try Vulkan',
                    'why': '',
                    'model': '*',
                    'key': '',
                    'value': 'vulkan',
                  },
                ],
              };
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Code').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tuning-ask')));
    await tester.pumpAndSettle();
    expect(asked, ['claude']);
    expect(find.text('Two things.'), findsOneWidget);
    expect(
      find.text('cache-type-k = q8_0 · room\nHalf the memory.'),
      findsOneWidget,
    );
    expect(find.textContaining('then compare.'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    expect(changes, [('room', 'cache-type-k', 'q8_0')]);
  });

  testWidgets('no agent for AI checks: no tips section', (tester) async {
    await pump(tester, 'llamacpp');
    expect(find.text('Tips from an agent'), findsNothing);
  });
}
