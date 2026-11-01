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
        'provider': '',
      },
      {
        'id': 'found:llm',
        'kind': 'runtime',
        'label': 'Ollama',
        'path': '/data/ollama',
        'found': 'b',
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
