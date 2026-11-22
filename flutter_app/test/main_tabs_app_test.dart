import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/agent_map.dart';
import 'package:maprisma/ai_project_center.dart';
import 'package:maprisma/main.dart';
import 'package:maprisma/map_editor.dart' show MapEditor;
import 'package:maprisma/settings_view.dart';

import 'package:maprisma/agent_list_view.dart';
import 'package:maprisma/map_legend.dart';
import 'package:maprisma/map_smart_card.dart';

import 'task_cards_app_test.dart'
    show mountApp, openFromHelp, requests, settleService, unmountApp;

/// The Projects and AI Map tabs in the real window (task 086), against the
/// widget tests' Python service.
void main() {
  const draft = {
    'id': 'p1',
    'title': 'Website relaunch',
    'brief': 'Relaunch the website.',
    'path': '/tmp/site',
    'status': 'draft',
    'phase': 'planning',
    'revision': 1,
    'team': [],
    'plan': '',
    'plan_version': 0,
    'approved_version': null,
    'events': [],
  };

  void projects(
    Directory dir, {
    Map<String, dynamic>? summary,
    Map<String, dynamic>? settings,
  }) {
    File('${dir.path}/projects.json').writeAsStringSync(jsonEncode([draft]));
    File('${dir.path}/summary.json').writeAsStringSync(
      jsonEncode(
        summary ??
            {
              'running': 0,
              'pausing': 0,
              'waiting': 0,
              'attention': 0,
              'attention_projects': 0,
              'needs_you': 0,
              'ready': 0,
              'drafts': 1,
              'finished': 0,
              'total': 1,
              'by_agent': {},
              'connected': true,
            },
      ),
    );
    if (settings != null) {
      File(
        '${dir.path}/start-settings.json',
      ).writeAsStringSync(jsonEncode(settings));
    }
  }

  Finder projectsPage() => find.byType(AiProjectCenterPage);

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleService(tester);
  }

  Future<void> editTitle(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'Website relaunch, changed',
    );
    await tester.pump();
  }

  Iterable<Map<String, dynamic>> calls(Directory dir, String method) =>
      requests(dir).where((q) => q['method'] == method);

  testWidgets('a start with a project opens Projects and defers the map', (
    tester,
  ) async {
    final dir = await mountApp(tester, beforeStart: projects);
    expect(projectsPage(), findsOneWidget);
    expect(find.byType(AgentMap), findsNothing);
    expect(find.text('Website relaunch'), findsWidgets);
    // No Project Center symbol and no Back on the page: the tab replaces it.
    expect(find.byKey(const ValueKey('ai-project-center-open')), findsNothing);
    expect(find.widgetWithText(TextButton, 'Back'), findsNothing);
    // The hidden map's scans, usage and traffic polls pause.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(seconds: 2));
    }
    expect(calls(dir, 'map.snapshot'), isEmpty);
    expect(calls(dir, 'agents.traffic'), isEmpty);
    expect(calls(dir, 'map.usage'), isEmpty);
    // The map: its first scan now, and the choice is remembered.
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(calls(dir, 'map.snapshot'), isNotEmpty);
    expect(
      calls(
        dir,
        'settings.update',
      ).map((q) => jsonEncode(q['params']['values'])),
      contains(jsonEncode({'main_tab': 'map'})),
    );
    await unmountApp(tester);
  });

  testWidgets('the saved tab wins over the projects', (tester) async {
    await mountApp(
      tester,
      beforeStart: (dir) => projects(dir, settings: {'main_tab': 'map'}),
    );
    expect(find.byType(AgentMap), findsOneWidget);
    expect(projectsPage(), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('no projects and nothing saved: the AI Map', (tester) async {
    await mountApp(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(projectsPage(), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('Ctrl+1 and Ctrl+2 switch the tabs, F5 refreshes the list', (
    tester,
  ) async {
    final dir = await mountApp(
      tester,
      beforeStart: (dir) => projects(dir, settings: {'main_tab': 'map'}),
    );
    await ctrl(tester, LogicalKeyboardKey.digit1);
    expect(projectsPage(), findsOneWidget);
    expect(
      calls(
        dir,
        'settings.update',
      ).map((q) => jsonEncode(q['params']['values'])),
      contains(jsonEncode({'main_tab': 'projects'})),
    );
    final before = calls(
      dir,
      'features.call',
    ).where((q) => q['params']['refresh'] == true).length;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settleService(tester);
    final refreshed = calls(
      dir,
      'features.call',
    ).where((q) => q['params']['refresh'] == true).toList();
    expect(refreshed.length, before + 1);
    expect(refreshed.last['params']['operation'], 'list');
    await ctrl(tester, LogicalKeyboardKey.digit2);
    expect(find.byType(AgentMap), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('unsaved changes ask before the AI Map; Cancel stays', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    await editTitle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    // One departure at a time; the tab keys do nothing under the dialog.
    await ctrl(tester, LogicalKeyboardKey.digit2);
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    // Discard: the map.
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Settings over Projects returns to the same page', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    final page = tester.state(projectsPage());
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    final typing = FocusManager.instance.primaryFocus;
    expect(typing?.context?.widget, isA<Focus>());
    // Settings while the field has the keyboard: Settings over Projects.
    await tester.tap(find.byTooltip('Settings'));
    await settleService(tester);
    expect(find.byType(SettingsView), findsOneWidget);
    expect(projectsPage(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    // The page was kept, with its selection and fields.
    expect(identical(tester.state(projectsPage()), page), isTrue);
    // And the keyboard is back in the field it was in.
    expect(FocusManager.instance.primaryFocus, same(typing));
    // Help (a card over the page), then Esc: the same.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    expect(find.text('Help'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(FocusManager.instance.primaryFocus, same(typing));
    // An edit saved on the way to Settings: the keyboard comes back too.
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'Saved on the way',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project goal'),
      'Build it.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/tmp',
    );
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleService(tester);
    expect(find.byType(SettingsView), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(FocusManager.instance.primaryFocus, same(typing));
    await unmountApp(tester);
  });

  testWidgets('Ask AI from Projects works on the AI Map', (tester) async {
    await mountApp(tester, beforeStart: projects);
    await tester.tap(find.byKey(const ValueKey('ask-ai-open')));
    await settleService(tester);
    expect(projectsPage(), findsNothing);
    expect(find.byType(AgentMap), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('closing: Discard, then cancelling the stop keeps the draft', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    await mountApp(
      tester,
      beforeStart: (dir) => projects(
        dir,
        summary: {
          'running': 1,
          'pausing': 0,
          'total': 1,
          'needs_you': 0,
          'attention_projects': 0,
          'connected': true,
        },
      ),
    );
    await editTitle(tester);
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    expect(
      find.text('Close Maprisma and stop its running agents?'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('the tab shows the counts and the store fault on the map too', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) => projects(
        dir,
        settings: {'main_tab': 'map'},
        summary: {
          'running': 1,
          'pausing': 1,
          'needs_you': 2,
          'attention': 1,
          'attention_projects': 0,
          'total': 4,
          'error': 'store unreadable',
          'connected': true,
        },
      ),
    );
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.byKey(const ValueKey('tab-projects-running')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tab-projects-needs-you')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('tab-projects-attention')), findsNothing);
    expect(find.byKey(const ValueKey('tab-projects-fault')), findsOneWidget);
    await unmountApp(tester);
  });

  void mockWindow(WidgetTester tester, List<String> calls) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
  }

  testWidgets('a summary not read in time starts on the map; late, no switch', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/slow_summary').writeAsStringSync('');
      },
    );
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(seconds: 1));
    }
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(projectsPage(), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('choosing the tab already shown is remembered too', (
    tester,
  ) async {
    final dir = await mountApp(tester, beforeStart: projects);
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    await settleService(tester);
    expect(
      calls(
        dir,
        'settings.update',
      ).map((q) => jsonEncode(q['params']['values'])),
      contains(jsonEncode({'main_tab': 'projects'})),
    );
    await unmountApp(tester);
  });

  testWidgets('Help › Agents from Projects shows the agents on the AI Map', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    await openFromHelp(tester, 'Agents');
    expect(projectsPage(), findsNothing);
    expect(find.byType(AgentListView), findsOneWidget);
    // Esc goes back to the map, which is now the tab in view.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Reports over Projects, then Ask AI: the card on the map', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    await tester.tap(find.byKey(const ValueKey('reports-open')));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('ask-ai-open')));
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(
      tester
          .widget<MapSmartCard>(find.byKey(const ValueKey('ask-ai-card')))
          .open,
      isTrue,
    );
    await unmountApp(tester);
  });

  testWidgets('Esc on Projects leaves the text field, then closes', (
    tester,
  ) async {
    final window = <String>[];
    mockWindow(tester, window);
    await mountApp(tester, beforeStart: projects);
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    expect(window, isNot(contains('close')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(window, contains('close'));
    await unmountApp(tester);
  });

  testWidgets('the window focused again: the next list reads fresh', (
    tester,
  ) async {
    final dir = await mountApp(tester, beforeStart: projects);
    int refreshed() => calls(
      dir,
      'features.call',
    ).where((q) => q['params']['refresh'] == true).length;
    final before = refreshed();
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowBlur();
    await settleService(tester);
    app.onWindowFocus();
    await settleService(tester);
    expect(refreshed(), before + 1);
    await unmountApp(tester);
  });

  testWidgets('narrow: the actions in More, no Legend on Projects', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    tester.view.physicalSize = const Size(480, 600);
    await settleService(tester);
    expect(find.byKey(const ValueKey('header-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('reports-open')), findsNothing);
    expect(find.byType(MapLegendButton), findsNothing);
    expect(find.byKey(const ValueKey('tab-projects')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('header-more')));
    await settleService(tester);
    await tester.tap(find.text('Settings').last);
    await settleService(tester);
    expect(find.byType(SettingsView), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('during the close questions no other departure starts', (
    tester,
  ) async {
    mockWindow(tester, []);
    await mountApp(
      tester,
      beforeStart: (dir) =>
          projects(dir, summary: {'running': 1, 'total': 1, 'connected': true}),
    );
    await editTitle(tester);
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    // Settings, Help and the tabs: nothing asks again under the question.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    expect(find.text('Save project changes?'), findsNothing);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('edits made while Help loads are asked about before Help', (
    tester,
  ) async {
    final dir = await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/slow_help.snapshot').writeAsStringSync('');
      },
    );
    await tester.tap(find.byKey(const ValueKey('help-open')));
    await settleService(tester);
    await editTitle(tester);
    File('${dir.path}/release_help.snapshot').writeAsStringSync('');
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Help › Agents, Esc: the map scans though scans are manual', (
    tester,
  ) async {
    final dir = await mountApp(
      tester,
      beforeStart: (dir) => projects(dir, settings: {'map_scan_interval': 0}),
    );
    await openFromHelp(tester, 'Agents');
    expect(find.byType(AgentListView), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.byKey(const ValueKey('map-loading')), findsNothing);
    expect(calls(dir, 'map.snapshot'), isNotEmpty);
    await unmountApp(tester);
  });

  testWidgets('leaving while the departure saves says to wait', (tester) async {
    final dir = await mountApp(tester, beforeStart: projects);
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'A new goal',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project goal'),
      'Build it.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/tmp',
    );
    await tester.pump();
    File('${dir.path}/slow_features.call').writeAsStringSync('');
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleService(tester);
    // The save is on its way: Settings waits and says so.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    expect(find.text('Wait for the current step'), findsOneWidget);
    expect(find.byType(SettingsView), findsNothing);
    // Closing the window meanwhile says the same.
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).clearSnackBars();
    await tester.pump(const Duration(seconds: 1));
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await tester.pump();
    expect(find.text('Wait for the current step'), findsOneWidget);
    File('${dir.path}/release_features.call').writeAsStringSync('');
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('a departure that does not happen keeps the field\'s keyboard', (
    tester,
  ) async {
    mockWindow(tester, []);
    final dir = await mountApp(
      tester,
      beforeStart: (dir) =>
          projects(dir, summary: {'running': 1, 'total': 1, 'connected': true}),
    );
    // A save the service refuses, after the fields were locked: the page
    // stays, so does the keyboard.
    await tester.enterText(
      find.widgetWithText(TextField, 'Project goal'),
      'Build it.',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Working folder'),
      '/tmp',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Project title'),
      'A title',
    );
    await tester.pump();
    final typing = FocusManager.instance.primaryFocus;
    File('${dir.path}/slow_features.call').writeAsStringSync('');
    File('${dir.path}/error_features.call').writeAsStringSync('');
    await tester.tap(find.byTooltip('Settings'));
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleService(tester);
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Project title'))
          .enabled,
      isFalse,
    );
    // F1 while that save runs: no Help, a note to wait.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await tester.pump();
    expect(find.text('Wait for the current step'), findsOneWidget);
    File('${dir.path}/release_features.call').writeAsStringSync('');
    await settleService(tester);
    File('${dir.path}/error_features.call').deleteSync();
    expect(find.byType(SettingsView), findsNothing);
    expect(find.text('Help'), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(typing));
    // Closing: Save, then Cancel at "stop running agents?".
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(FocusManager.instance.primaryFocus, same(typing));
    await unmountApp(tester);
  });

  testWidgets('F1 under the save question opens nothing later', (tester) async {
    final dir = await mountApp(tester, beforeStart: projects);
    await editTitle(tester);
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    File('${dir.path}/slow_help.snapshot').writeAsStringSync('');
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    File('${dir.path}/release_help.snapshot').writeAsStringSync('');
    await settleService(tester);
    // No second question and no Help: the project as it was.
    expect(find.text('Save project changes?'), findsNothing);
    expect(projectsPage(), findsOneWidget);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('F1 under the page\'s own save question opens nothing later', (
    tester,
  ) async {
    final dir = await mountApp(tester, beforeStart: projects);
    await editTitle(tester);
    // Another project chosen in the list: the page asks by itself.
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.add));
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    File('${dir.path}/slow_help.snapshot').writeAsStringSync('');
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    File('${dir.path}/release_help.snapshot').writeAsStringSync('');
    await settleService(tester);
    expect(find.text('Save project changes?'), findsNothing);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('a close the service refuses keeps the discarded draft', (
    tester,
  ) async {
    mockWindow(tester, []);
    final dir = await mountApp(
      tester,
      beforeStart: (dir) =>
          projects(dir, summary: {'running': 1, 'total': 1, 'connected': true}),
    );
    await editTitle(tester);
    for (final name in ['slow', 'error', 'release']) {
      File('${dir.path}/${name}_features.shutdown').writeAsStringSync('');
    }
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await settleService(tester);
    // The service could not stop everything: the window and the draft stay.
    expect(projectsPage(), findsOneWidget);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('F1 under the page\'s delete question opens nothing later', (
    tester,
  ) async {
    final dir = await mountApp(tester, beforeStart: projects);
    await tester.tap(find.text('Website relaunch').first);
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await settleService(tester);
    expect(find.text('Delete saved project?'), findsOneWidget);
    File('${dir.path}/slow_help.snapshot').writeAsStringSync('');
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    // Under the page's own question: no note to wait, just nothing.
    expect(find.text('Wait for the current step'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    File('${dir.path}/release_help.snapshot').writeAsStringSync('');
    await settleService(tester);
    expect(find.byKey(const ValueKey('help-tab-Agents')), findsNothing);
    expect(projectsPage(), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('closing under the page\'s question does not close later', (
    tester,
  ) async {
    final window = <String>[];
    mockWindow(tester, window);
    final dir = await mountApp(tester, beforeStart: projects);
    await tester.tap(find.text('Website relaunch').first);
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete project'));
    await settleService(tester);
    expect(find.text('Delete saved project?'), findsOneWidget);
    File('${dir.path}/slow_features.summary').writeAsStringSync('');
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    File('${dir.path}/release_features.summary').writeAsStringSync('');
    await settleService(tester);
    expect(window, isNot(contains('destroy')));
    expect(projectsPage(), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Ctrl+, under the page\'s save question keeps the question', (
    tester,
  ) async {
    await mountApp(tester, beforeStart: projects);
    await editTitle(tester);
    await tester.tap(find.widgetWithIcon(FilledButton, Icons.add));
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleService(tester);
    expect(find.byType(SettingsView), findsNothing);
    // The keyboard is still in the question: Esc cancels it.
    final focus = FocusManager.instance.primaryFocus;
    expect(
      focus?.context != null && ModalRoute.of(focus!.context!) is DialogRoute,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.text('Save project changes?'), findsNothing);
    expect(find.text('Website relaunch, changed'), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('the board: Esc and the Projects tab go back from a project', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
      },
    );
    expect(find.byKey(const ValueKey('project-card-p1')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
    // Esc: back to the board (the window stays).
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byKey(const ValueKey('project-card-p1')), findsOneWidget);
    // Open again, then the Projects tab: the board.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsNothing);
    expect(find.byKey(const ValueKey('project-card-p1')), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Esc in a field of an open project leaves the field first', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextField, 'Project title'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('while closing, Esc keeps the open project', (tester) async {
    mockWindow(tester, []);
    final dir = await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    File('${dir.path}/slow_features.summary').writeAsStringSync('');
    final dynamic app = tester.state(find.byType(MaprismaApp));
    app.onWindowClose();
    await settleService(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
    File('${dir.path}/release_features.summary').writeAsStringSync('');
    await settleService(tester);
    await unmountApp(tester);
  });

  testWidgets('Show on map from a team member, through the save question; '
      'Used in N projects back to the board with the agent chip', (
    tester,
  ) async {
    late Directory home;
    await mountApp(
      tester,
      beforeStart: (dir) {
        home = dir;
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
        final summary =
            jsonDecode(File('${dir.path}/summary.json').readAsStringSync())
                as Map;
        summary['by_agent'] = {'test': 1};
        File('${dir.path}/summary.json').writeAsStringSync(jsonEncode(summary));
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'goal',
              'activity': 'draft',
              'bucket': 'drafts',
              'planning': [],
              'execution': [
                {
                  'phase': 'execution',
                  'position': 0,
                  'agent': 'test',
                  'name': 'Test agent',
                  'role': 'lead',
                  'issues': [],
                },
              ],
            },
          ]),
        );
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await editTitle(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await settleService(tester);
    final show = find.byKey(const ValueKey('graph-show-execution-0'));
    await tester.ensureVisible(show);
    await tester.pumpAndSettle();
    await tester.tap(show);
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
    expect(find.byType(AgentMap), findsNothing);
    await tester.tap(show);
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(
      tester.widget<MapEditor>(find.byType(MapEditor)).focused,
      'agent:test',
    );
    // Temporary: nothing about the layout was saved.
    expect(
      calls(home, 'settings.update').where(
        (q) =>
            (q['params'] as Map)['values'] is Map &&
            ((q['params'] as Map)['values'] as Map).containsKey(
              'flutter_map_layout',
            ),
      ),
      isEmpty,
    );
    // The mark goes after a while.
    await tester.pump(const Duration(seconds: 7));
    await settleService(tester);
    expect(tester.widget<MapEditor>(find.byType(MapEditor)).focused, isNull);
    // Used in 1 project: Projects with the agent chip.
    await tester.tap(find.byKey(const ValueKey('used-in-badge')));
    await settleService(tester);
    expect(projectsPage(), findsOneWidget);
    final chip = find.byKey(const ValueKey('board-agent'));
    expect(chip, findsOneWidget);
    expect(
      find.descendant(of: chip, matching: find.text('Test agent')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('project-card-p1')), findsOneWidget);
    // Back to the map: the chip goes with the Projects page.
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    await settleService(tester);
    expect(find.byKey(const ValueKey('board-agent')), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('Show on map for an agent that is not on the map says so', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'goal',
              'activity': 'draft',
              'bucket': 'drafts',
              'planning': [],
              'execution': [
                {
                  'phase': 'execution',
                  'position': 0,
                  'agent': 'gone',
                  'name': 'gone',
                  'role': 'lead',
                  'issues': [],
                },
              ],
            },
          ]),
        );
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await settleService(tester);
    final show = find.byKey(const ValueKey('graph-show-execution-0'));
    await tester.ensureVisible(show);
    await tester.pumpAndSettle();
    await tester.tap(show);
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.text('This agent is not on the map.'), findsOneWidget);
    expect(tester.widget<MapEditor>(find.byType(MapEditor)).focused, isNull);
    await unmountApp(tester);
  });

  testWidgets('Show on map waits for the map refresh: an agent added '
      'meanwhile is revealed, not reported missing', (tester) async {
    late Directory home;
    await mountApp(
      tester,
      beforeStart: (dir) {
        home = dir;
        projects(dir, settings: {'main_tab': 'map'});
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'goal',
              'activity': 'draft',
              'bucket': 'drafts',
              'planning': [],
              'execution': [
                {
                  'phase': 'execution',
                  'position': 0,
                  'agent': 'later',
                  'name': 'Later agent',
                  'role': 'lead',
                  'issues': [],
                },
              ],
            },
          ]),
        );
      },
    );
    // The map was read without the agent.
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.text('Later agent'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    await settleService(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await settleService(tester);
    // Installed meanwhile; the next map read is held back.
    File('${home.path}/agent_later').writeAsStringSync('');
    File('${home.path}/slow_map.snapshot').writeAsStringSync('');
    final show = find.byKey(const ValueKey('graph-show-execution-0'));
    await tester.ensureVisible(show);
    await tester.pumpAndSettle();
    await tester.tap(show);
    await settleService(tester);
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.text('This agent is not on the map.'), findsNothing);
    expect(tester.widget<MapEditor>(find.byType(MapEditor)).reveal, isNull);
    File('${home.path}/release_map.snapshot').writeAsStringSync('');
    await settleService(tester);
    await tester.pumpAndSettle();
    expect(find.text('This agent is not on the map.'), findsNothing);
    expect(find.text('Later agent'), findsOneWidget);
    expect(
      tester.widget<MapEditor>(find.byType(MapEditor)).focused,
      'agent:later',
    );
    // The reveal ran after the refresh: its timer takes the mark away.
    await tester.pump(const Duration(seconds: 7));
    await settleService(tester);
    expect(tester.widget<MapEditor>(find.byType(MapEditor)).focused, isNull);
    await unmountApp(tester);
  });

  testWidgets('Show on map, then the map left before its refresh: no late '
      'reveal, no lasting mark', (tester) async {
    late Directory home;
    await mountApp(
      tester,
      beforeStart: (dir) {
        home = dir;
        projects(dir, settings: {'main_tab': 'map'});
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'goal',
              'activity': 'draft',
              'bucket': 'drafts',
              'planning': [],
              'execution': [
                {
                  'phase': 'execution',
                  'position': 0,
                  'agent': 'test',
                  'name': 'Test agent',
                  'role': 'lead',
                  'issues': [],
                },
              ],
            },
          ]),
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('tab-projects')));
    await settleService(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await settleService(tester);
    File('${home.path}/slow_map.snapshot').writeAsStringSync('');
    final show = find.byKey(const ValueKey('graph-show-execution-0'));
    await tester.ensureVisible(show);
    await tester.pumpAndSettle();
    await tester.tap(show);
    await settleService(tester);
    // The agent's details opened while the read is on its way: the map is
    // left (the AI Map tab stays).
    await tester.tap(
      find
          .descendant(
            of: find
                .ancestor(
                  of: find.text('Test agent'),
                  matching: find.byType(Card),
                )
                .first,
            matching: find.byTooltip('Actions'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Details').last);
    await settleService(tester);
    expect(find.byType(AgentMap), findsNothing);
    File('${home.path}/release_map.snapshot').writeAsStringSync('');
    await settleService(tester);
    // Back on the map: nothing was waiting.
    await tester.tap(find.byKey(const ValueKey('ai-map-open')));
    await settleService(tester);
    final editor = tester.widget<MapEditor>(find.byType(MapEditor));
    expect(editor.reveal, isNull);
    expect(editor.focused, isNull);
    await unmountApp(tester);
  });

  testWidgets('Show on map whose first map read fails: no mark, and the read '
      'that works later neither pans nor marks', (tester) async {
    late Directory home;
    await mountApp(
      tester,
      beforeStart: (dir) {
        home = dir;
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'goal',
              'activity': 'draft',
              'bucket': 'drafts',
              'planning': [],
              'execution': [
                {
                  'phase': 'execution',
                  'position': 0,
                  'agent': 'test',
                  'name': 'Test agent',
                  'role': 'lead',
                  'issues': [],
                },
              ],
            },
          ]),
        );
      },
    );
    // Started on Projects: the map was not read yet.
    expect(calls(home, 'map.snapshot'), isEmpty);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Team'));
    await settleService(tester);
    File('${home.path}/slow_map.snapshot').writeAsStringSync('');
    File('${home.path}/error_map.snapshot').writeAsStringSync('');
    final show = find.byKey(const ValueKey('graph-show-execution-0'));
    await tester.ensureVisible(show);
    await tester.pumpAndSettle();
    await tester.tap(show);
    await settleService(tester);
    File('${home.path}/release_map.snapshot').writeAsStringSync('');
    await settleService(tester);
    // The read failed; it works again and the map is read on F5.
    File('${home.path}/error_map.snapshot').deleteSync();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await settleService(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AgentMap), findsOneWidget);
    final editor = tester.widget<MapEditor>(find.byType(MapEditor));
    expect(editor.reveal, isNull);
    expect(editor.focused, isNull);
    await unmountApp(tester);
  });

  testWidgets('Fix on map from a card: the runtime\'s box is revealed', (
    tester,
  ) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'approval',
              'activity': 'approved_blocked',
              'bucket': 'needs_you',
              'planning': [],
              'execution': [],
              'issues': [
                {
                  'code': 'runtime_stopped',
                  'target': 'runtime',
                  'node': 'runtime:fixture',
                  'fix': 'map',
                },
              ],
            },
          ]),
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('card-fix')));
    await settleService(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AgentMap), findsOneWidget);
    expect(
      tester.widget<MapEditor>(find.byType(MapEditor)).focused,
      'runtime:fixture',
    );
    expect(find.text('This is not on the map.'), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('Fix on map from the project page asks about unsaved changes; '
      'a box not on the map says so', (tester) async {
    await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
        File('${dir.path}/projects.json').writeAsStringSync(
          jsonEncode([
            {
              ...draft,
              'stage': 'approval',
              'activity': 'approved_blocked',
              'bucket': 'needs_you',
              'planning': [],
              'execution': [],
              'issues': [
                {
                  'code': 'runtime_stopped',
                  'target': 'runtime',
                  'node': 'runtime:gone',
                  'fix': 'map',
                },
              ],
            },
          ]),
        );
      },
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('project-card-p1')),
        matching: find.byKey(const ValueKey('card-open')),
      ),
    );
    await settleService(tester);
    await editTitle(tester);
    final fix = find.byKey(const ValueKey('page-fix-0'));
    await tester.ensureVisible(fix);
    await tester.pumpAndSettle();
    await tester.tap(fix);
    await settleService(tester);
    expect(find.text('Save project changes?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(find.byKey(const ValueKey('breadcrumb-projects')), findsOneWidget);
    expect(find.byType(AgentMap), findsNothing);
    await tester.tap(fix);
    await settleService(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Discard'));
    await settleService(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AgentMap), findsOneWidget);
    expect(find.text('This is not on the map.'), findsOneWidget);
    expect(tester.widget<MapEditor>(find.byType(MapEditor)).focused, isNull);
    await unmountApp(tester);
  });

  testWidgets('under the card\'s delete question, F1, Ctrl+2 and Ctrl+, '
      'do nothing', (tester) async {
    final dir = await mountApp(
      tester,
      beforeStart: (dir) {
        projects(dir);
        File('${dir.path}/board').writeAsStringSync('');
      },
    );
    await tester.tap(find.byKey(const ValueKey('card-delete')));
    await settleService(tester);
    expect(find.text('Delete saved project?'), findsOneWidget);
    File('${dir.path}/slow_help.snapshot').writeAsStringSync('');
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    await ctrl(tester, LogicalKeyboardKey.digit2);
    await ctrl(tester, LogicalKeyboardKey.comma);
    // The question stays, nothing else happened.
    expect(find.text('Delete saved project?'), findsOneWidget);
    expect(find.text('Wait for the current step'), findsNothing);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    File('${dir.path}/release_help.snapshot').writeAsStringSync('');
    await settleService(tester);
    expect(find.byKey(const ValueKey('help-tab-Agents')), findsNothing);
    expect(find.byType(SettingsView), findsNothing);
    expect(projectsPage(), findsOneWidget);
    expect(find.byKey(const ValueKey('project-card-p1')), findsOneWidget);
    await unmountApp(tester);
  });
}
