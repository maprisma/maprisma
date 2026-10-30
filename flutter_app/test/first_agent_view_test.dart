import 'review_test_host.dart';
import 'package:asterism/first_agent_view.dart';
import 'package:asterism/installer_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final route = {
    'id': 'fixture-online',
    'kind': 'online',
    'title': 'Fixture online',
    'access': 'Test account',
    'command': 'fixture',
    'verified': false,
    'steps': [
      {
        'title': 'A test question',
        'done': false,
        'detail': 'Test the agent',
        'action': 'verify',
      },
    ],
  };
  testWidgets('guide selects known routes and sends only named step actions', (
    tester,
  ) async {
    String? chosen;
    List<String>? action;
    Widget view(String? selected) => MaterialApp(
      home: Scaffold(
        body: FirstAgentView(
          data: {
            'routes': [route],
            'selected': selected,
          },
          busy: false,
          tr: (key) => key,
          onChoose: (id) => chosen = id,
          onAction: (command, name) => action = [command, name],
          onBack: () {},
          onRefresh: () {},
        ),
      ),
    );
    await tester.pumpWidget(view(null));
    await tester.tap(find.text('Fixture online'));
    expect(chosen, 'fixture-online');
    await tester.pumpWidget(view('fixture-online'));
    await tester.tap(find.text('Send the test question'));
    expect(action, ['fixture', 'verify']);
  });

  testWidgets('agent action shows command and kept data before confirmation', (
    tester,
  ) async {
    bool? accepted;
    final plan = {
      'action': 'uninstall',
      'name': 'Fixture',
      'external': true,
      'note': '',
      'url': '',
      'commands': ['mise uninstall fixture'],
      'data': ['~/fixture-data'],
      'runnable': true,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('review'),
              onPressed: () async {
                accepted = await confirmAgentAction(
                  context,
                  plan,
                  (key) => key,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('review'));
    await tester.pumpAndSettle();
    expect(find.text('mise uninstall fixture'), findsOneWidget);
    expect(find.text('What stays: ~/fixture-data'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });

  testWidgets('install steps name their tool or local LLM, not the agent', (
    tester,
  ) async {
    final actions = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FirstAgentView(
            data: {
              'routes': [
                {
                  ...route,
                  'steps': [
                    {
                      'title': 'mise',
                      'done': false,
                      'detail': '',
                      'action': 'install-tool',
                      'target': 'mise',
                    },
                    {
                      'title': 'node',
                      'done': false,
                      'detail': '',
                      'action': 'install-node',
                      'target': 'node',
                    },
                    {
                      'title': 'llama.cpp',
                      'done': false,
                      'detail': '',
                      'action': 'install-runtime',
                      'target': 'llamacpp',
                    },
                  ],
                },
              ],
              'selected': 'fixture-online',
            },
            busy: false,
            tr: (key) => key,
            onChoose: (_) {},
            onAction: (command, name) => actions.add([command, name]),
            onBack: () {},
            onRefresh: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Install mise'));
    await tester.tap(find.text('Install Node.js'));
    await tester.tap(find.text('Install llama.cpp…'));
    expect(actions, [
      ['mise', 'install-tool'],
      ['fixture', 'install-node'],
      ['llamacpp', 'install-runtime'],
    ]);
  });

  testWidgets('installer review shows the release and keeps the choices', (
    tester,
  ) async {
    final choice = InstallerChoice('vulkan');
    var confirmed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallerReview(
            preview: {
              'name': 'llama.cpp',
              'version': 'b9000-vulkan',
              'files': [
                {
                  'name': 'llama-b9000-bin-ubuntu-vulkan-x64.tar.gz',
                  'size': 52428800,
                },
              ],
              'folder': '/home/u/.local/share/maprisma/llamacpp',
              'models': '/home/u/.local/share/maprisma/llamacpp/models',
              'gpu': {'vendor': 'amd', 'name': 'AMD · card1'},
              'build': 'vulkan',
              'builds': [
                ['vulkan', 'Vulkan'],
                ['cpu', 'CPU'],
              ],
              'has_service': true,
            },
            choice: choice,
            tr: (key) => key,
            onConfirm: () => confirmed = true,
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(
      find.textContaining('llama-b9000-bin-ubuntu-vulkan-x64.tar.gz · 50 MiB'),
      findsOneWidget,
    );
    expect(find.text('Install'), findsOneWidget);
    await tester.ensureVisible(find.text('Start at login'));
    await tester.tap(find.text('Start at login'));
    await tester.pump();
    expect(choice.startAtLogin, isTrue);
    await tester.ensureVisible(find.text('CPU'));
    await tester.tap(find.text('CPU'));
    await tester.pump();
    expect(choice.build, 'cpu');
    expect(
      find.text('Change'),
      findsOneWidget,
    ); // another build is looked up first
    await tester.tap(find.text('Change'));
    expect(confirmed, isTrue);
  });

  testWidgets('a local route offers the starter model for its local LLM', (
    tester,
  ) async {
    (String, Map<String, dynamic>)? downloaded;
    List<String>? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FirstAgentView(
            data: {
              'routes': [
                {
                  'id': 'pi-local',
                  'kind': 'local',
                  'title': 'Pi with llama.cpp',
                  'access': 'This PC',
                  'command': 'pi',
                  'verified': false,
                  'steps': [
                    {
                      'title': 'A model',
                      'done': false,
                      'detail':
                          'Suggested: Gemma 4 12B, 7.0 GB (fits your graphics card: yes)',
                      'action': 'download-starter',
                      'target': 'llamacpp',
                      'starter': {
                        'title': 'Gemma 4 12B',
                        'repo': 'lmstudio-community/gemma-4-12B-it-QAT-GGUF',
                        'file': 'gemma-4-12B-it-QAT-Q4_0.gguf',
                        'size': 6980000000,
                      },
                    },
                  ],
                },
              ],
              'selected': 'pi-local',
            },
            busy: false,
            tr: (key) => key,
            onChoose: (_) {},
            onAction: (command, name) => action = [command, name],
            onStarter: (key, starter) => downloaded = (key, starter),
            onBack: () {},
            onRefresh: () {},
          ),
        ),
      ),
    );
    expect(
      find.text(
        'Suggested: Gemma 4 12B, 7.0 GB (fits your graphics card: yes)',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Download it'));
    expect(downloaded?.$1, 'llamacpp');
    expect(downloaded?.$2['file'], 'gemma-4-12B-it-QAT-Q4_0.gguf');
    expect(action, isNull);
  });
}
