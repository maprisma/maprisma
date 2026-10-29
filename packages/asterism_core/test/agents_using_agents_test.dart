import 'package:asterism_core/src/activity_readers.dart' show agentsUsingAgents;
import 'package:test/test.dart';

void main() {
  test('an agent started by another (through a shell) is used by it', () {
    // 100 claude → 200 bash → 300 pi; 400 codex inside 500 codex; 600 pi alone.
    const parents = {300: 200, 200: 100, 100: 1, 400: 500, 500: 1, 600: 1};
    int parent(int pid) => parents[pid] ?? 0;
    expect(
      agentsUsingAgents({
        'claude': [100],
        'pi': [300, 600],
        'codex': [400, 500],
      }, parent),
      {('claude', 'pi')},
    );
  });

  test('only as many parents as asked are followed', () {
    final parents = {for (var p = 2; p < 40; p++) p: p + 1};
    int parent(int pid) => parents[pid] ?? 0;
    expect(
      agentsUsingAgents({
        'claude': [30],
        'pi': [2],
      }, parent),
      isEmpty,
    );
    expect(
      agentsUsingAgents({
        'claude': [10],
        'pi': [2],
      }, parent),
      {('claude', 'pi')},
    );
  });
}
