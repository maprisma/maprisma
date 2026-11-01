import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/found_on_pc_view.dart';

void main() {
  Future<List<(String, String?)>> mount(
    WidgetTester tester,
    List<Map<String, dynamic>> nodes,
  ) async {
    final calls = <(String, String?)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FoundOnPcView(
            nodes: nodes,
            tr: (s) => s,
            onReconnect: (source, target) =>
                calls.add(('${source['id']}', target?['id'] as String?)),
            onClose: () {},
          ),
        ),
      ),
    );
    return calls;
  }

  testWidgets('what is already connected is no find, but still a folder', (
    tester,
  ) async {
    await mount(tester, [
      {
        'id': 'folder:/data/models',
        'kind': 'models',
        'label': 'In use',
        'path': '/data/models',
        'found': 'a',
        'status': 'present',
        'provider': '',
      },
      {
        'id': 'runtime:ollama',
        'kind': 'runtime',
        'label': 'Connected',
        'path': '/data/ollama',
        'found': 'b',
        'status': 'running',
        'provider': 'ollama',
      },
      {
        'id': 'found:llm',
        'kind': 'runtime',
        'label': 'New',
        'path': '/data/llm',
        'found': 'c',
        'status': 'found',
        'provider': 'ollama',
      },
    ]);
    expect(find.text('In use'), findsNothing);
    expect(find.text('Connected'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('found-folder-found:llm')));
    await tester.pumpAndSettle();
    expect(find.text('/data/models'), findsWidgets);
  });

  testWidgets('a found model folder can be reused, a runtime reconnected', (
    tester,
  ) async {
    final calls = await mount(tester, [
      {
        'id': 'found:folder',
        'kind': 'models',
        'label': 'Models',
        'path': '/data/models',
        'found': 'a',
        'status': 'found',
        'provider': '',
      },
      {
        'id': 'found:llm',
        'kind': 'runtime',
        'label': 'Ollama',
        'path': '/data/ollama',
        'found': 'b',
        'status': 'found',
        'provider': 'ollama',
      },
      {
        'id': 'found:gone',
        'kind': 'models',
        'label': 'Gone',
        'path': '/gone',
        'found': 'c',
        'status': 'missing',
        'provider': '',
      },
      {'id': 'disk:1', 'kind': 'disk', 'label': 'Disk', 'path': '/'},
    ]);
    expect(find.text('Gone'), findsNothing);
    expect(find.text('Disk'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('found-reuse-found:folder')));
    expect(calls.single, ('found:folder', null));
    final reconnect = find.byKey(const ValueKey('found-reconnect-found:llm'));
    expect(tester.widget<FilledButton>(reconnect).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('found-folder-found:llm')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/data/models').last);
    await tester.pumpAndSettle();
    await tester.tap(reconnect);
    expect(calls.last, ('found:llm', 'found:folder'));
  });

  testWidgets('nothing found says so', (tester) async {
    await mount(tester, const []);
    expect(find.text('Nothing new found.'), findsOneWidget);
  });
}
