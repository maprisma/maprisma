import 'dart:convert';
import 'dart:io';

/// args: feature id, then an optional mode: `legacy` (no handle provenance)
/// `slow-shutdown` (answers @shutdown late) or `refuse-shutdown` (the first @shutdown is refused, as for unconfirmed
/// project cleanup).
Future<void> main(List<String> args) async {
  final mode = args.length > 1 ? args[1] : '';
  var refused = false;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    final method = request['method'];
    if (method == 'crash') exit(17);
    if (method == '@shutdown' && mode == 'slow-shutdown') {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (method == '@shutdown' && mode == 'refuse-shutdown' && !refused) {
      refused = true;
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'error': {'code': 'project_still_pausing'},
        }),
      );
      continue;
    }
    final result = method == '@hello'
        ? {'id': args.firstOrNull ?? 'reports', 'api': 1}
        : method == '@shutdown'
        ? {'ok': true}
        : {
            'method': method,
            'echo': request['params'],
            'undo': 'core-${'b' * 32}',
            'nested': {'task': 'core-${'a' * 32}'},
            // An issued handle without the prefix, and a digest of the same
            // shape that this feature did not issue.
            'preview': 'c' * 32,
            'digest': 'd' * 32,
          };
    final response = jsonEncode({
      'id': request['id'],
      'result': result,
      if (mode != 'legacy' && method != '@hello' && method != '@shutdown')
        'handles': ['core-${'b' * 32}', 'core-${'a' * 32}', 'c' * 32],
    });
    // Deliberately split UTF-8 and JSON frames across pipe writes.
    stdout.write(response.substring(0, 4));
    await stdout.flush();
    stdout.writeln(response.substring(4));
    if (method == '@shutdown') return;
  }
}
