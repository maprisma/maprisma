import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/core_client.g.dart';
import 'package:maprisma/dictation_card.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:maprisma/settings_view.dart';
import 'package:maprisma_core/maprisma_core.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('maprisma-dictation-ui-test-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  CoreClient clientFor(CoreService core) => CoreClient.fromCall(
    (method, params) async => core.dispatch(method, params),
  );

  testWidgets(
    'Settings Dictation card shows unconfigured hint, Omarchy and Whisper setup, online cost warning, test dictation, and off switch',
    (tester) async {
      final fixture = <String, dynamic>{
        'omarchy': {
          'supported': true,
          'ready': false,
          'voxtype_installed': false,
          'superwhisper_configured': false,
          'monologue_installed': false,
          'label': 'Omarchy dictation',
        },
        'whisper': {
          'program_installed': false,
          'ready': false,
          'models': const [],
        },
        'local': {'ready': false, 'models': const []},
        'online': {'provider': 'OpenAI', 'ready': false},
        'text': 'Dictated test sentence',
      };
      var core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
          'MAPRISMA_TEST_DICTATION': jsonEncode(fixture),
        },
      );
      var settings = Map<String, dynamic>.from(
        core.dispatch('settings.get', {}),
      );

      Widget buildSettings() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DictationSection(
              settings: settings,
              busy: false,
              tr: (k) => k,
              client: clientFor(core),
              onUpdate: (values) async {
                settings = Map<String, dynamic>.from(
                  core.dispatch('settings.update', {'values': values}),
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              settings: settings,
              busy: false,
              tr: (k) => k,
              client: clientFor(core),
              onBack: () {},
              onUpdate: (values) async {},
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-dictation-card')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('settings-dictation-card')),
        findsOneWidget,
      );

      await tester.pumpWidget(buildSettings());
      await tester.pumpAndSettle();

      // Default is on and unconfigured -> yellow hint badge.
      expect(
        find.byKey(const ValueKey('dictation-status-unconfigured')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dictation-install-voxtype')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dictation-install-monologue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('dictation-install-whisper')),
        findsOneWidget,
      );

      // Install Omarchy Monologue and Whisper actions route through dictation.run.
      await tester.tap(
        find.byKey(const ValueKey('dictation-install-monologue')),
      );
      await tester.pumpAndSettle();
      expect(
        core.dictation.testActions.any(
          (a) => a['action'] == 'install_monologue',
        ),
        isTrue,
      );

      // Now simulate local Whisper ready and online provider ready.
      fixture['whisper'] = {
        'program_installed': true,
        'ready': true,
        'active_model': 'ggml-base.bin',
        'models': [
          {
            'name': 'ggml-base.bin',
            'path': '/tmp/ggml-base.bin',
            'managed': true,
          },
        ],
      };
      fixture['online'] = {'provider': 'OpenAI', 'ready': true};
      core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
          'MAPRISMA_TEST_DICTATION': jsonEncode(fixture),
        },
      );

      await tester.pumpWidget(buildSettings());
      dictationChanged.value++;
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('dictation-status-ready')),
        findsOneWidget,
      );

      // Test dictation records and populates the test text field.
      await tester.tap(find.byKey(const ValueKey('dictation-test-button')));
      await tester.pumpAndSettle();
      expect(find.text('Stop'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dictation-test-button')));
      await tester.pumpAndSettle();
      expect(find.text('Dictated test sentence'), findsOneWidget);
      expect(find.byKey(const ValueKey('dictation-test-meta')), findsOneWidget);

      // Switching to online shows the cost warning.
      settings = Map<String, dynamic>.from(
        core.dispatch('settings.update', {
          'values': {'dictation_engine': 'online'},
        }),
      );
      await tester.pumpWidget(buildSettings());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dictation-cost-warning')),
        findsOneWidget,
      );

      // Turning off dictation folds the controls and shows Off.
      await tester.tap(find.byKey(const ValueKey('dictation-switch')));
      await tester.pumpWidget(buildSettings());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('dictation-status-off')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('dictation-test-card')), findsNothing);
    },
  );

  testWidgets(
    'Ask AI shows microphone with unconfigured hint, opens inline setup, and dictates into prompt when ready',
    (tester) async {
      final fixture = <String, dynamic>{
        'omarchy': {'supported': true, 'ready': false},
        'whisper': {'program_installed': false, 'ready': false},
        'local': {'ready': false},
        'online': {'provider': 'OpenAI', 'ready': false},
        'text': 'Connect filesystem MCP server',
      };
      var core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
          'MAPRISMA_TEST_DICTATION': jsonEncode(fixture),
        },
      );

      Widget buildCard() => MaterialApp(
        home: Scaffold(
          body: MapSmartCard(
            width: 360,
            column: 'mcp',
            title: 'MCP servers and skills',
            open: true,
            enabled: true,
            onToggle: () {},
            tr: (k) => k,
            helpers: const [
              {'command': 'claude', 'name': 'Claude Code', 'local': false},
            ],
            client: clientFor(core),
          ),
        ),
      );

      await tester.pumpWidget(buildCard());
      await tester.pumpAndSettle();

      // Microphone is shown with yellow unconfigured indicator.
      expect(find.byKey(const ValueKey('smart-dictation-mic')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('smart-dictation-unconfigured')),
        findsOneWidget,
      );

      // Tapping mic when unconfigured opens the inline dictation setup panel inside Ask AI.
      await tester.tap(find.byKey(const ValueKey('smart-dictation-mic')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('smart-dictation-panel')),
        findsOneWidget,
      );

      // Now make online dictation ready and verify cost hint + dictation into prompt.
      fixture['online'] = {'provider': 'OpenAI', 'ready': true};
      core = CoreService(
        environment: {
          'HOME': temp.path,
          'PATH': '${temp.path}/bin',
          'MAPRISMA_DESKTOP': 'omarchy',
          'MAPRISMA_TEST_DICTATION': jsonEncode(fixture),
        },
      );
      await tester.pumpWidget(buildCard());
      dictationChanged.value++;
      await tester.pumpAndSettle();

      // Close inline setup panel to see cost hint and dictate.
      await tester.tap(find.byKey(const ValueKey('smart-dictation-manage')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('smart-dictation-cost-hint')),
        findsOneWidget,
      );

      // Start and stop dictation -> inserts text into Ask AI prompt field.
      await tester.tap(find.byKey(const ValueKey('smart-dictation-mic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('smart-dictation-mic')));
      await tester.pumpAndSettle();
      expect(find.text('Connect filesystem MCP server'), findsOneWidget);

      // Disabling dictation in settings hides the microphone button.
      core.dispatch('settings.update', {
        'values': {'dictation': false},
      });
      dictationChanged.value++;
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('smart-dictation-mic')), findsNothing);
    },
  );
}
