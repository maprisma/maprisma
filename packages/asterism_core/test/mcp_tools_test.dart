import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/src/core_tasks.dart';
import 'package:asterism_core/src/mcp_tools.dart';
import 'package:test/test.dart';

const _server = r'''
import json, sys
for line in sys.stdin:
    q = json.loads(line)
    if "id" not in q:
        continue
    if q["method"] == "initialize":
        r = {"capabilities": {}, "serverInfo": {"name": "fixture", "version": "1"}}
    else:
        r = {"tools": [{"name": "hello", "description": "Says hello"}]}
    print(json.dumps({"jsonrpc": "2.0", "id": q["id"], "result": r}), flush=True)
''';

Map<String, dynamic> _entry(String script) => {
  'transport': 'stdio',
  'command': 'python3',
  'args': [script],
  'env': {'SECRET_KEY': 'kept-private'},
  'url': '',
  'headers': <String, String>{},
};

void main() {
  late Directory home;
  late String script;
  setUp(() {
    home = Directory.systemTemp.createTempSync('asterism-mcp-tools-');
    script = '${home.path}/server.py';
    File(script).writeAsStringSync(_server);
  });
  tearDown(() => home.deleteSync(recursive: true));

  test('a set-up server asked through the private worker', () async {
    final tasks = CoreTasks([
      Platform.resolvedExecutable,
      '--disable-dart-dev',
      '--packages=.dart_tool/package_config.json',
      'bin/asterism-core.dart',
      'worker',
    ]);
    final started = tasks.startPrivate(
      'mcp.tools_test',
      utf8.encode(jsonEncode({'entry': _entry(script)})),
    );
    var status = tasks.status(started['task'] as String);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (status['state'] == 'running' && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      status = tasks.status(started['task'] as String);
    }
    expect(status['state'], 'done', reason: '$status');
    final result = status['result'] as Map;
    expect(result['status'], 'ok');
    expect(result['server'], 'fixture 1');
    expect((result['tools'] as List).single['name'], 'hello');
  });

  test('the answer, or the failure, is kept under the server name', () async {
    final written = <String, List<int>>{};
    final ok = await askAndKeep(
      'fixture',
      _entry(script),
      home: home.path,
      environment: Platform.environment,
      write: (path, bytes) => written[path] = bytes,
    );
    expect(ok['status'], 'ok');
    final path = '${home.path}/.cache/ai-agents-map/mcp-tools/fixture.json';
    expect(jsonDecode(utf8.decode(written[path]!))['tools'], ok['tools']);
    final failed = await askAndKeep(
      'broken',
      {..._entry(script), 'command': '${home.path}/missing'},
      home: home.path,
      environment: Platform.environment,
      write: (path, bytes) => written[path] = bytes,
    );
    expect(failed['status'], 'failed');
    expect(failed['error'], 'the server stopped');
    expect(() => toolsCacheFile(home.path, 'bad\nname'), throwsFormatException);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(written[path]!);
    expect(cachedTools(home.path, 'fixture')!['status'], 'ok');
    expect(cachedTools(home.path, 'missing'), isNull);
  });
}
