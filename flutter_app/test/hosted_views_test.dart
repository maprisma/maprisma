import 'package:maprisma/connections_view.dart';
import 'package:maprisma/first_agent_view.dart';
import 'package:maprisma/map_addons_focus.dart';
import 'package:maprisma/providers_view.dart';
import 'package:maprisma/task_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'hosted views keep one heading/Back and retain secondary actions',
    (tester) async {
      var undo = 0, refresh = 0;
      final views = <String, Widget>{
        'Connections': ConnectionsView(
          hosted: true,
          data: const {'agents': [], 'providers': [], 'mcp': [], 'skills': []},
          busy: false,
          tr: (s) => s,
          onPreview: (_) async {},
          onBack: () {},
          onUndo: () => undo++,
        ),
        'Providers and models': ProvidersView(
          hosted: true,
          data: const {'local': [], 'online': []},
          busy: false,
          tr: (s) => s,
          onOperation: (_, _, _) async => null,
          onBack: () {},
        ),
        'Your first agent': FirstAgentView(
          hosted: true,
          data: const {},
          busy: false,
          tr: (s) => s,
          onChoose: (_) {},
          onAction: (_, _) {},
          onBack: () {},
          onRefresh: () => refresh++,
        ),
        'Agents': MapAddonsFocus(
          hosted: true,
          category: 1,
          items: const [],
          nodes: const [],
          entries: const [],
          detected: const {},
          busy: false,
          running: false,
          online: true,
          tr: (s) => s,
          onBack: () {},
          onToggle: (_, _) async {},
          onCatalog: () {},
          onOnline: (_) {},
          onInstall: (_) {},
          onMenu: (_, _) {},
          onNode: (_) {},
          onModels: () {},
          onConnections: () {},
          onFolders: () {},
        ),
      };
      for (final entry in views.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TaskHost(
                spec: TaskCardSpec(
                  title: entry.key,
                  child: entry.value,
                  width: TaskCardWidth.full,
                ),
                graph: const {'nodes': [], 'edges': []},
                tr: (s) => s,
                onClose: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(entry.key), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
        if (entry.key == 'Connections') await tester.tap(find.text('Undo'));
        if (entry.key == 'Your first agent') {
          await tester.tap(find.text('Refresh'));
        }
        expect(tester.takeException(), isNull);
      }
      expect(undo, 1);
      expect(refresh, 1);
    },
  );
  testWidgets(
    'hosted model browser fills card without a second heading/close',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskHost(
              spec: TaskCardSpec(
                title: 'Download model · Fixture',
                width: TaskCardWidth.full,
                child: ModelBrowser(
                  hosted: true,
                  runtime: const {
                    'key': 'test',
                    'name': 'Fixture',
                    'download': 'file',
                  },
                  tr: (s) => s,
                  onOperation: (_, _, _) async => null,
                  onClose: () {},
                ),
              ),
              graph: const {'nodes': [], 'edges': []},
              tr: (s) => s,
              onClose: () {},
            ),
          ),
        ),
      );
      expect(find.text('Download model · Fixture'), findsOneWidget);
      expect(find.byTooltip('Close'), findsNothing);
      expect(
        tester.getSize(find.byType(ModelBrowser)).width,
        greaterThan(1000),
      );
      expect(
        tester.getSize(find.byType(ModelBrowser)).height,
        greaterThan(620),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
