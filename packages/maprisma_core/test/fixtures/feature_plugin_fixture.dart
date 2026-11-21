import 'dart:convert';
import 'dart:io';

/// args: feature id, then an optional mode: `legacy` (no handle provenance)
/// `slow-shutdown` (answers @shutdown late) or `refuse-shutdown` (the first @shutdown is refused, as for unconfirmed
/// project cleanup). With a third argument, a file: each start appends a line
/// to it (to count launches). Modes combine with `+`; `barrier-exit` exits
/// (on SIGTERM or after @shutdown) only once `<file>.release` exists.
Future<void> main(List<String> args) async {
  final modes = (args.length > 1 ? args[1] : '').split('+');
  final mode = modes.first;
  Future<Never> leave() async {
    if (modes.contains('barrier-exit')) {
      // A finished test (its folder removed) or 30 s also release it, so
      // no fixture outlives its test.
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (!File('${args[2]}.release').existsSync() &&
          File(args[2]).parent.existsSync() &&
          DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    await stdout.flush();
    exit(0);
  }

  if (args.length > 2) {
    File(args[2]).writeAsStringSync('start\n', mode: FileMode.append);
  }
  if (modes.contains('barrier-exit')) {
    // Like a worker still cleaning up: SIGTERM ends it only when released.
    ProcessSignal.sigterm.watch().listen((_) => leave());
  }
  var refused = false;
  // `pair-issue` is answered only together with the next `pair-release`,
  // both answers in one write (as a pipe may deliver them).
  Object? pairId;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    final method = request['method'];
    if (method == 'crash') exit(17);
    if (method == 'garbage') {
      stdout.writeln('not a frame');
      continue;
    }
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
    if (method == 'pair-issue') {
      pairId = request['id'];
      continue;
    }
    if (method == 'pair-release') {
      stdout.write(
        '${jsonEncode({
          'id': pairId,
          'result': {'task': 'core-${'a' * 32}'},
          'handles': ['core-${'a' * 32}'],
        })}\n${jsonEncode({
          'id': request['id'],
          'result': {'ok': true},
          'released': ['a' * 32],
        })}\n',
      );
      await stdout.flush();
      continue;
    }
    if (method == 'release-error' || method == 'bad-release') {
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'error': {'code': 'proposal_expired'},
          'released': method == 'bad-release' ? 5 : ['a' * 32],
        }),
      );
      continue;
    }
    if (method == 'fresh') {
      // A new handle on every call.
      final handle =
          'core-${(DateTime.now().microsecondsSinceEpoch + request['id'] as int).toRadixString(16).padLeft(32, '0')}';
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'result': {'handle': handle},
          'handles': [handle],
        }),
      );
      continue;
    }
    if (method == 'tasks.status') {
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'result': {'state': 'done', 'operation': 'providers.run'},
        }),
      );
      continue;
    }
    final result = method == 'release'
        ? {'released': true}
        : method == '@hello'
        ? {
            'id': args.firstOrNull ?? 'reports',
            // `api2`: the newer API with a capability; `api3`: one no host
            // accepts; `badcaps`: a capability list of the wrong shape.
            'api': modes.contains('api2')
                ? 2
                : modes.contains('api3')
                ? 3
                : 1,
            if (modes.contains('api2') &&
                !modes.contains('nullcaps') &&
                !modes.contains('emptycap'))
              'capabilities': ['summary2'],
            if (modes.contains('badcaps')) 'capabilities': 5,
            if (modes.contains('nullcaps')) 'capabilities': null,
            if (modes.contains('emptycap')) 'capabilities': [''],
          }
        : method == '@shutdown'
        ? {'ok': true}
        : {
            'method': method,
            'echo': request['params'],
            'context': ?request['context'],
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
      // `release`: its stores let go of the nested task handle.
      if (method == 'release') 'released': ['a' * 32],
      if (mode != 'legacy' &&
          method != '@hello' &&
          method != '@shutdown' &&
          method != 'release')
        'handles': ['core-${'b' * 32}', 'core-${'a' * 32}', 'c' * 32],
    });
    // Deliberately split UTF-8 and JSON frames across pipe writes.
    stdout.write(response.substring(0, 4));
    await stdout.flush();
    stdout.writeln(response.substring(4));
    // `eof-exit`: after @shutdown it waits for EOF, as the contract allows.
    if (method == '@shutdown' && !modes.contains('eof-exit')) await leave();
  }
}
