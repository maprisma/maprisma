import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/src/red_limits.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('maprisma-red-'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('levels, red limits and plain text', () {
    expect(warnLevels(75, 90), (0.75, 0.9));
    expect(warnLevels(85, 80), (0.75, 0.9)); // red must be above yellow
    final now = DateTime.utc(2026, 10, 29, 12);
    expect(
      redLimits(
        [
          {
            'label': 'Week',
            'percent': 0.9,
            'resets_at': '2026-11-01T00:00:00Z',
          },
          {
            'label': 'Past',
            'percent': 1.0,
            'resets_at': '2026-10-28T00:00:00Z',
          },
          {'label': 'Low', 'percent': 0.5, 'resets_at': null},
        ],
        0.9,
        now,
      ).map((l) => l['label']),
      ['Week'],
    );
    expect(
      plainText('<b>5 h</b> &\n limit', 80),
      'b5 h/b  limit',
    ); // as ai_core.plain_text
    expect(plainText('x' * 100, 10), '${'x' * 9}…');
  });

  test('one notification per limit and reset, kept across restarts', () {
    final path = '${dir.path}/red-notified.json';
    File(path).writeAsStringSync(
      jsonEncode({
        'limit:old:x:2026-01-01': '2026-01-01',
        'keep': '2026-10-28',
      }),
    );
    final sent = <(String, String)>[];
    RedLimits red() => RedLimits(
      path,
      send: (t, b) {
        sent.add((t, b));
        return true;
      },
    );
    final now = DateTime.utc(2026, 10, 29, 12);
    final agents = {
      'claude': (
        'Claude Code',
        <Map>[
          {
            'label': '5 h',
            'percent': 0.95,
            'resets_at': '2026-10-29T15:00:00Z',
          },
        ],
      ),
    };
    void write(String p, List<int> b) => File(p).writeAsBytesSync(b);
    expect(red().check(agents, 0.9, now, (t) => t, write), hasLength(1));
    expect(sent.single.$1, 'Claude Code is in the red');
    expect(sent.single.$2, startsWith('5 h: 95 % used, resets '));
    expect(red().check(agents, 0.9, now, (t) => t, write), isEmpty);
    final kept = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(
      kept.containsKey('limit:old:x:2026-01-01'),
      isFalse,
    ); // older than 8 days
    expect(kept['keep'], '2026-10-28');
  });

  test('nothing sent when what was shown cannot be kept', () {
    var sent = 0;
    final red = RedLimits(
      '${dir.path}/red-notified.json',
      send: (_, _) {
        sent++;
        return true;
      },
    );
    final agents = {
      'codex': (
        'Codex',
        <Map>[
          {'label': 'week', 'percent': 1.0, 'resets_at': null},
        ],
      ),
    };
    final found = red.check(
      agents,
      0.9,
      DateTime.utc(2026, 10, 29),
      (t) => t,
      (_, _) => throw const FileSystemException('read-only'),
    );
    expect(found, isEmpty);
    expect(sent, 0);
  });
}
