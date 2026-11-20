import 'dart:io';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/core_client.g.dart';
import 'package:maprisma/provider_config_view.dart';
import 'package:maprisma/connections_view.dart';
import 'package:maprisma/app_theme.dart';
import 'package:maprisma/app_look.dart';
import 'package:maprisma_core/src/provider_config.dart';
import 'support/provider_config_fixture.dart';

void main() {
  final shots = Platform.environment['MAPRISMA_CONFIG_SHOTS'];
  if (shots != null) {
    setUpAll(() async {
      final fonts = Platform.environment['MAPRISMA_SHOT_FONTS']!;
      for (final (family, file) in [
        ('Roboto', 'Roboto-Regular.ttf'),
        ('MaterialIcons', 'MaterialIcons-Regular.otf'),
      ]) {
        final loader = FontLoader(family)
          ..addFont(
            File(
              '$fonts/$file',
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
        await loader.load();
      }
    });
  }
  late Map<String, dynamic> facts, draft;
  late List<(String, Map<String, dynamic>)> calls;
  late CoreClient client;
  final jobs = <String, Map<String, dynamic>>{};
  setUp(() {
    facts = configurationFixture('llamacpp');
    draft = {};
    calls = [];
    jobs.clear();
    client = CoreClient.fromCall((method, params) async {
      calls.add((method, Map.of(params)));
      if (method == 'models.config_check') {
        return {
          ...ConfigMath(
            facts,
            '${params['model']}',
          ).validate(params['values'] as Map),
          if (facts['writable'] != true) 'snippet': facts['snippet'],
        };
      }
      if (method == 'models.config_preview') {
        return {
          'ok': true,
          'plan': 'preview',
          'files': [],
          'links_add': [],
          'links_remove': [],
        };
      }
      if (method == 'models.config') {
        facts = configurationFixture(
          '${facts['key']}',
          model: '${params['model']}',
          profile: '${params['profile']}',
        );
        jobs['read'] = facts;
        return {'task': 'read'};
      }
      if (method == 'models.config_ask') {
        jobs['ask'] = {
          'summary': 'Fits this PC',
          'values': {'ctx-size': 16384},
          'reasons': {'ctx-size': 'Leaves headroom'},
          'config_proposal': 'ai-handle',
          'sources': ['https://example.com/provider-docs'],
        };
        return {'task': 'ask'};
      }
      if (method == 'tasks.status') {
        return {'state': 'done', 'result': jobs[params['task']]};
      }
      if (method == 'tasks.cancel') return {'state': 'stopped'};
      throw StateError(method);
    });
  });
  Future<void> mount(
    WidgetTester tester, {
    Future<bool> Function(Map<String, dynamic>, Map<String, dynamic>)? apply,
    double width = 1050,
    Brightness brightness = Brightness.light,
    GlobalKey? boundary,
  }) async {
    tester.view.resetPhysicalSize();
    await tester.binding.setSurfaceSize(Size(width, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(
            brightness,
            fonts: shots == null
                ? const {}
                : const {'ui': 'Roboto', 'mono': 'Roboto'},
          ),
          home: Scaffold(
            body: Column(
              children: [
                WindowHeader(
                  title: 'Configuration · ${facts['runtime']}',
                  tr: (s) => s,
                  onBack: () {},
                ),
                Expanded(
                  child: ProviderConfigurationView(
                    facts: facts,
                    client: client,
                    draft: draft,
                    tr: (s) => s,
                    onClose: () {},
                    onApply: apply ?? (p, o) async => false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Key key) async {
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets('recommended values, typed edits and reset are validated', (
    tester,
  ) async {
    await mount(tester);
    final apply = find.byKey(const ValueKey('config-apply'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    await tap(tester, const ValueKey('config-recommended'));
    expect(draft['values']['ctx-size'], 131072);
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    final field = find.byKey(const ValueKey('config-ctx-size'));
    await tester.enterText(field, '2048');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(draft['values']['ctx-size'], 2048);
    expect(find.byKey(const ValueKey('config-ctx-size')), findsOneWidget);
    await tap(tester, const ValueKey('config-reset'));
    expect(draft['values'], isEmpty);
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'AI web opt-in and exact provenance survive Cancel; edits drop it',
    (tester) async {
      final previews = <Map>[];
      await mount(
        tester,
        apply: (p, o) async {
          previews.add(p);
          return false;
        },
      );
      await tap(tester, const ValueKey('config-web'));
      await tap(tester, const ValueKey('config-ask'));
      expect(
        calls.lastWhere((c) => c.$1 == 'models.config_ask').$2['web_search'],
        true,
      );
      expect(draft['config_proposal'], 'ai-handle');
      await tap(tester, const ValueKey('config-apply'));
      expect(previews.length, 1);
      expect(draft['config_proposal'], 'ai-handle');
      expect(
        calls.lastWhere((c) => c.$1 == 'models.config_preview').$2['values'],
        {'ctx-size': 16384},
      );
      expect(
        calls
            .lastWhere((c) => c.$1 == 'models.config_preview')
            .$2['config_proposal'],
        'ai-handle',
      );
      final input = find.byKey(const ValueKey('config-ctx-size'));
      await tester.ensureVisible(input);
      await tester.enterText(input, '24576');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(draft.containsKey('config_proposal'), false);
      expect(find.text('From Ask AI'), findsNothing);
    },
  );
  testWidgets('scope/profile edits refresh; advanced/default controls work', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, const ValueKey('profile-long_context'));
    expect(
      calls.lastWhere((c) => c.$1 == 'models.config').$2['profile'],
      'long_context',
    );
    final chooser = find.byKey(const ValueKey('config-model-*'));
    await tester.ensureVisible(chooser);
    await tester.tap(chooser);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Qwen 7B Q4').last);
    await tester.pumpAndSettle();
    expect(draft['model'], 'Qwen 7B Q4');
    await tap(tester, const ValueKey('default-ctx-size'));
    expect(draft['values'].containsKey('ctx-size'), true);
    expect(draft['values']['ctx-size'], isNull);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('config-ctx-size')))
          .controller!
          .text,
      '',
    );
    await tap(tester, const ValueKey('config-advanced'));
    expect(find.byKey(const ValueKey('config-threads')), findsOneWidget);
  });
  testWidgets(
    'special chip replaces numeric text without leaving a stale value',
    (tester) async {
      await mount(tester);
      final input = find.byKey(const ValueKey('config-gpu-layers'));
      await tester.enterText(input, '20');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ChoiceChip, 'all'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(draft['values']['gpu-layers'], 'all');
      expect(tester.widget<TextFormField>(input).controller!.text, '');
    },
  );
  testWidgets(
    'return from a cancelled review retains facts for the selected profile',
    (tester) async {
      await mount(tester);
      await tap(tester, const ValueKey('profile-long_context'));
      await tester.enterText(
        find.byKey(const ValueKey('config-ctx-size')),
        '24576',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(const SizedBox.shrink());
      facts = configurationFixture('llamacpp');
      await mount(tester);
      expect(draft['profile'], 'long_context');
      expect(draft['values']['ctx-size'], 24576);
      expect(find.text('q4_0'), findsWidgets);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('config-ctx-size')),
            )
            .controller!
            .text,
        '24576',
      );
    },
  );
  testWidgets('stale preview shows Read again and disables Apply', (
    tester,
  ) async {
    final base = client;
    client = CoreClient.fromCall(
      (method, params) => method == 'models.config_preview'
          ? Future.value({'error': 'stale'})
          : base.transport.call(method, params),
    );
    await mount(tester);
    await tester.enterText(
      find.byKey(const ValueKey('config-ctx-size')),
      '16384',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tap(tester, const ValueKey('config-apply'));
    await tester.ensureVisible(find.text('Read again'));
    await tester.pumpAndSettle();
    expect(
      find.text('Read the configuration again before applying.'),
      findsWidgets,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('config-apply')))
          .onPressed,
      isNull,
    );
  });
  for (final immediate in [true, false]) {
    testWidgets('stale AI ${immediate ? 'reply' : 'job'} asks to read again', (
      tester,
    ) async {
      final base = client;
      client = CoreClient.fromCall((method, params) async {
        if (method == 'models.config_ask') {
          return immediate ? {'error': 'stale'} : {'task': 'stale-ask'};
        }
        if (method == 'tasks.status' && params['task'] == 'stale-ask') {
          return {
            'state': 'done',
            'result': {'error': 'stale'},
          };
        }
        return base.transport.call(method, params);
      });
      await mount(tester);
      await tap(tester, const ValueKey('config-recommended'));
      await tap(tester, const ValueKey('config-ask'));
      expect(
        find.text('Read the configuration again before applying.'),
        findsWidgets,
      );
      expect(
        find.text('The helper did not return a valid configuration.'),
        findsNothing,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('config-apply')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.text('Read again'));
      await tester.tap(find.text('Read again'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        find.text('Read the configuration again before applying.'),
        findsNothing,
      );
    });
  }
  testWidgets('switching to a local helper clears and disables web research', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, const ValueKey('config-web'));
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('config-web')))
          .value,
      true,
    );
    final chooser = find.byType(DropdownButton<String>).last;
    await tester.ensureVisible(chooser);
    await tester.tap(chooser);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local helper').last);
    await tester.pumpAndSettle();
    final web = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('config-web')),
    );
    expect(web.value, false);
    expect(web.onChanged, isNull);
    await tap(tester, const ValueKey('config-ask'));
    expect(
      calls.lastWhere((c) => c.$1 == 'models.config_ask').$2['web_search'],
      false,
    );
  });
  testWidgets('facts reload clears web opt-in when its helper is unavailable', (
    tester,
  ) async {
    final base = client;
    client = CoreClient.fromCall((method, params) async {
      if (method == 'models.config_ask') return {'error': 'stale'};
      if (method == 'models.config') {
        jobs['read-local'] = {
          ...configurationFixture('llamacpp'),
          'helpers': [
            {
              'command': 'local-helper',
              'name': 'Local helper',
              'local': true,
              'web_search': false,
            },
          ],
        };
        return {'task': 'read-local'};
      }
      return base.transport.call(method, params);
    });
    await mount(tester);
    await tap(tester, const ValueKey('config-web'));
    expect(
      tester
          .widget<CheckboxListTile>(find.byKey(const ValueKey('config-web')))
          .value,
      true,
    );
    await tap(tester, const ValueKey('config-ask'));
    await tester.ensureVisible(find.text('Read again'));
    await tester.tap(find.text('Read again'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final web = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('config-web')),
    );
    expect(web.onChanged, isNull);
    expect(web.value, false);
  });
  testWidgets(
    'Apply disables immediately during typed and stepper validation',
    (tester) async {
      await mount(tester);
      await tap(tester, const ValueKey('config-recommended'));
      final apply = find.byKey(const ValueKey('config-apply'));
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      final field = find.byKey(const ValueKey('config-ctx-size'));
      await tester.ensureVisible(field);
      await tester.enterText(field, '16384');
      await tester.pump();
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.tap(find.byKey(const ValueKey('increase-ctx-size')));
      await tester.pump();
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    },
  );
  for (final provider in ['llamacpp', 'vllm', 'ollama']) {
    testWidgets('$provider shows only its own build information', (
      tester,
    ) async {
      facts = {...configurationFixture(provider), 'build': 'vulkan'};
      await mount(tester);
      expect(
        find.textContaining('Build:'),
        provider == 'llamacpp' ? findsOneWidget : findsNothing,
      );
      if (provider == 'llamacpp') {
        expect(find.text('Build: Vulkan'), findsOneWidget);
      }
    });
  }
  for (final width in [1050.0, 500.0]) {
    testWidgets('special value stays beside its field at width $width', (
      tester,
    ) async {
      await mount(tester, width: width);
      final field = tester.getRect(
        find.byKey(const ValueKey('config-gpu-layers')),
      );
      final chip = tester.getRect(find.widgetWithText(ChoiceChip, 'all'));
      expect(chip.left, greaterThanOrEqualTo(field.right - 1));
      expect(
        (chip.center.dy - field.center.dy).abs(),
        lessThan(field.height / 2),
      );
      expect(tester.takeException(), isNull);
    });
  }
  for (final width in [500.0, 680.0, 700.0, 720.0, 1050.0, 1400.0]) {
    testWidgets('Jan inputs and both special choices work at width $width', (
      tester,
    ) async {
      facts = configurationFixture('jan');
      await mount(tester, width: width);
      final setting = (facts['schema'] as List).cast<Map>().singleWhere(
        (s) => (s['special'] as List? ?? const []).length == 2,
      );
      final id = '${setting['id']}';
      final field = find.byKey(ValueKey('config-$id'));
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();

      void checkSpace() {
        final fieldRect = tester.getRect(field);
        // RenderEditable excludes the decoration's padding and step buttons.
        final editable = tester
            .state<EditableTextState>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .renderEditable;
        expect(editable.size.width, greaterThanOrEqualTo(64));
        for (final v in [-2, -1]) {
          final chip = find.byKey(ValueKey('special-$id-$v'));
          expect(chip.hitTestable(), findsOneWidget);
          final chipRect = tester.getRect(chip);
          expect(chipRect.right, lessThanOrEqualTo(width));
          expect(chipRect.left, greaterThanOrEqualTo(fieldRect.right - 1));
          expect(
            (chipRect.center.dy - fieldRect.center.dy).abs(),
            lessThan(fieldRect.height / 2),
          );
        }
        expect(tester.takeException(), isNull);
      }

      checkSpace();
      await tester.enterText(field, '20');
      await tester.pump(const Duration(milliseconds: 300));
      expect(draft['values'][id], 20);
      await tap(tester, ValueKey('increase-$id'));
      expect(draft['values'][id], 21);
      expect(tester.widget<TextFormField>(field).controller!.text, '21');
      for (final v in [-2, -1]) {
        await tap(tester, ValueKey('special-$id-$v'));
        expect(draft['values'][id], v);
        expect(tester.widget<TextFormField>(field).controller!.text, '$v');
        checkSpace();
      }
      await tap(tester, ValueKey('increase-$id'));
      expect(draft['values'][id], 0);
      expect(tester.widget<TextFormField>(field).controller!.text, '0');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('advice-only provider shows a copyable snippet and no Apply', (
    tester,
  ) async {
    facts = configurationFixture('vllm');
    await mount(tester, width: 500);
    expect(find.byKey(const ValueKey('config-apply')), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('copy-config-snippet')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('vllm serve'), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('copy-config-snippet')));
    await tester.pumpAndSettle();
    expect(copied, contains('vllm serve'));
    expect(tester.takeException(), isNull);
  });
  testWidgets('cancelled AI job ignores its late proposal', (tester) async {
    final lateResult = Completer<Map<String, dynamic>>();
    final base = client;
    client = CoreClient.fromCall((method, params) async {
      if (method == 'models.config_ask') return {'task': 'late'};
      if (method == 'tasks.status' && params['task'] == 'late') {
        return lateResult.future;
      }
      if (method == 'tasks.cancel') {
        calls.add((method, params));
        return {'ok': true};
      }
      return base.transport.call(method, params);
    });
    await mount(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('config-ask')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('config-ask')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.any((c) => c.$1 == 'tasks.cancel'), true);
    lateResult.complete({
      'state': 'done',
      'result': {
        'values': {'ctx-size': 16384},
        'config_proposal': 'late-handle',
      },
    });
    await tester.pumpAndSettle();
    expect(draft['values'], isEmpty);
    expect(draft.containsKey('config_proposal'), false);
  });
  testWidgets(
    'invalid values block Apply; transient warning stays reviewable',
    (tester) async {
      await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('config-ctx-size')),
        '-1',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('config-apply')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('config-ctx-size')),
        '16384',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('config-apply')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets(
    'warnings need acknowledgement and busy keeps both actions disabled',
    (tester) async {
      var confirmed = 0, restart = false;
      final plan = <String, dynamic>{
        'files': [],
        'links_add': [],
        'links_remove': [],
        'restart': 'service',
        'warnings': [
          {'key': 'ctx', 'text': 'Memory warning'},
        ],
      };
      Widget review(bool busy) => MaterialApp(
        home: Scaffold(
          body: ConnectionReview(
            plan: plan,
            tr: (s) => s,
            busy: busy,
            onConfirm: () => confirmed++,
            onCancel: () {},
            restartLabel: 'Restart now',
            onRestartChanged: (v) => restart = v,
          ),
        ),
      );
      await tester.pumpWidget(review(false));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('configuration-warning-ack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('configuration-restart')));
      await tester.pumpAndSettle();
      expect(restart, true);
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      expect(confirmed, 1);
      await tester.pumpWidget(review(true));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Apply'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
    },
  );
  if (shots != null) {
    for (final provider in ['llamacpp', 'ollama', 'vllm']) {
      for (final mode in Brightness.values) {
        testWidgets('capture $provider ${mode.name}', (tester) async {
          facts = configurationFixture(provider);
          final boundary = GlobalKey();
          await mount(
            tester,
            boundary: boundary,
            brightness: mode,
            width: 1280,
          );
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            Directory(shots).createSync(recursive: true);
            File(
              '$shots/configuration-$provider-${mode.name}.png',
            ).writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        });
      }
    }
  }
}
