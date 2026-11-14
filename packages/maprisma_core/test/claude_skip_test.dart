import 'dart:io';

import 'package:maprisma_core/src/claude_sessions.dart';
import 'package:test/test.dart';

void main() {
  test('an overlong line is charged to the budget, resumed, never reread', () {
    final dir = Directory.systemTemp.createTempSync('maprisma-claude-skip-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/s.jsonl';
    final long = maxLine * 3;
    File(
      path,
    ).writeAsBytesSync(List.filled(long, 120)); // unfinished, > maxLine
    final reader = ClaudeSessions(dir.path, null);
    final state = <String, dynamic>{};
    final budget = maxLine + 100;
    final read = reader.readFile(path, state, budget);
    expect(read, lessThanOrEqualTo(budget));
    expect(state['offset'], greaterThan(0));
    expect(state['skipping'], isTrue);
    for (var i = 0; i < 10; i++) {
      reader.readFile(path, state, budget);
    }
    expect(state['offset'], long);
    File(path).writeAsStringSync('\n{"type": "user"}\n', mode: FileMode.append);
    reader.readFile(path, state, budget);
    expect(state['skipping'], isFalse);
    expect(state['offset'], File(path).lengthSync());
  });
}
