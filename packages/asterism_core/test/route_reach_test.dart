import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:test/test.dart';

/// Every route added in phase 6b reaches its own branch of dispatch: a
/// prefix route above it (mcp.*, addons.*) once answered for it instead.
/// Valid parameters in an empty HOME: an answer, or that route's own
/// "unknown" error, never another branch's. Worker tasks are left out.
void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('route-reach'));
  tearDown(() => home.deleteSync(recursive: true));

  test('each new route answers for itself', () {
    final core = CoreService(
      environment: {
        'HOME': home.path,
        'PATH': '/usr/bin:/bin',
        'ASTERISM_DESKTOP': 'generic',
        'LANG': 'C.UTF-8',
      },
    );
    const cases = <String, (Map<String, dynamic>, Set<String>)>{
      'addons.hints': ({}, {}),
      'found.hints': ({}, {}),
      'found.list': ({'kind': 'mcp'}, {}),
      'found.seen': ({'kind': 'skills'}, {}),
      'found.update_preview': ({}, {'Nothing to update'}),
      'found.unpack': ({'program': '/x'}, {'Unknown program'}),
      'map.badges': ({}, {}),
      'agents.costs': ({'command': 'claude'}, {'Unknown agent'}),
      'agents.projects': ({'command': 'claude'}, {'Unknown agent'}),
      'providers.details': ({'key': 'ollama'}, {'Unknown local LLM'}),
      'details.mcp': ({'name': 'none'}, {'Unknown MCP server'}),
      'details.skills': ({'path': '~/none'}, {'Unknown skill set'}),
      'limits.notify': ({}, {}),
    };
    for (final e in cases.entries) {
      try {
        final reply = core.dispatch(e.key, e.value.$1);
        expect(reply, isA<Map>(), reason: e.key);
      } on FormatException catch (error) {
        expect(e.value.$2, contains(error.message), reason: e.key);
      } on StateError catch (error) {
        fail('${e.key}: $error');
      }
    }
  });
}
