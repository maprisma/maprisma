import 'costs.dart' show shortNumber;
import 'py_values.dart' show pyFixedExact;
import 'session_readers.dart' show NumericSession;

/// claude_sessions.projects / subagents / busiest and
/// details_pages.fill_session_projects: an agent's last 30 days per project
/// folder (working time, sessions, tokens, lines changed, API value), its
/// subagent runs per type and its busiest hour; numbers only, no text.

final class Project {
  Project(this.cwd);
  final String cwd;
  int sessions = 0, tokens = 0, cacheRead = 0, linesAdded = 0;
  int linesRemoved = 0, subagentRuns = 0, subagentTokens = 0;
  double active = 0, cost = 0, last = 0;
}

void _stable<T>(List<T> items, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final c = compare(a.$2, b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  items
    ..clear()
    ..addAll(indexed.map((e) => e.$2));
}

/// projects: per project folder, the sessions last active since [since],
/// busiest first.
List<Project> projects(Iterable<NumericSession> sessions, double since) {
  final found = <String, Project>{};
  for (final s in sessions) {
    if (s.last < since) continue;
    final key = s.cwd.isEmpty ? '?' : s.cwd;
    final p = found.putIfAbsent(key, () => Project(key));
    p.sessions++;
    p.active += s.active;
    for (final c in s.tokens.values) {
      p.tokens += c[0] + c[1] + c[3];
      p.cacheRead += c[2];
    }
    p.linesAdded += s.linesAdded;
    p.linesRemoved += s.linesRemoved;
    p.cost += s.cost;
    if (s.last > p.last) p.last = s.last;
    for (final v in s.subagents.values) {
      p.subagentRuns += v[0].toInt();
      p.subagentTokens += v[1].toInt();
      p.tokens += v[1].toInt();
    }
  }
  final list = found.values.toList();
  _stable(list, (a, b) {
    final c = b.active.compareTo(a.active);
    return c != 0 ? c : b.tokens.compareTo(a.tokens);
  });
  return list;
}

/// busiest: (weekday 0 = Monday, hour) with the most replies, or null.
(int, int)? busiest(Iterable<NumericSession> sessions, double since) {
  final totals = <int, int>{};
  for (final s in sessions) {
    if (s.last < since) continue;
    for (final e in s.hours.entries) {
      final slot = int.tryParse(e.key);
      if (slot == null || !RegExp(r'^\d+$').hasMatch(e.key)) continue;
      totals[slot] = (totals[slot] ?? 0) + e.value;
    }
  }
  if (totals.isEmpty) return null;
  // max() keeps the first of equals, in the order the slots came.
  var best = totals.keys.first;
  for (final slot in totals.keys) {
    if (totals[slot]! > totals[best]!) best = slot;
  }
  return (best ~/ 24, best % 24);
}

/// subagents: (type, runs, tokens, working seconds), most runs first.
List<(String, int, int, double)> subagentRuns(
  Iterable<NumericSession> sessions,
  double since,
) {
  final totals = <String, List<num>>{};
  for (final s in sessions) {
    if (s.last < since) continue;
    for (final e in s.subagents.entries) {
      final t = totals.putIfAbsent(e.key, () => [0, 0, 0.0]);
      t[0] += e.value[0];
      t[1] += e.value[1];
      t[2] += e.value[2];
    }
  }
  final rows = [
    for (final e in totals.entries)
      (e.key, e.value[0].toInt(), e.value[1].toInt(), e.value[2].toDouble()),
  ];
  _stable(rows, (a, b) {
    final c = b.$2.compareTo(a.$2);
    return c != 0 ? c : b.$4.compareTo(a.$4);
  });
  return rows;
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// details_pages.duration_text.
String durationText(double seconds, String Function(String) tr) {
  final minutes = seconds ~/ 60;
  return minutes >= 60
      ? tr('{0} h {1} min')
            .replaceAll('{0}', '${minutes ~/ 60}')
            .replaceAll('{1}', '${minutes % 60}')
      : tr('{0} min').replaceAll('{0}', '$minutes');
}

/// fill_session_projects: the card's texts, null without projects.
Map<String, dynamic>? projectsCard(
  Iterable<NumericSession> sessions,
  double now,
  String note,
  String Function(String) tr,
  String Function(String, String, int) plural,
  String Function(String) tilde,
) {
  final since = now - 30 * 86400;
  final rows = projects(sessions, since);
  if (rows.isEmpty) return null;
  String count(String one, String other, int n) =>
      plural(one, other, n).replaceAll('{0}', '$n');
  final summary = [
    count('1 project', '{0} projects', rows.length),
    tr(
      '{0} tokens',
    ).replaceAll('{0}', shortNumber(rows.fold<int>(0, (n, r) => n + r.tokens))),
    tr('{0} working').replaceAll(
      '{0}',
      durationText(rows.fold<double>(0, (n, r) => n + r.active), tr),
    ),
  ].join(' · ');
  final runs = subagentRuns(sessions, since);
  final peak = busiest(sessions, since);
  return {
    'title': tr('Projects, last 30 days'),
    'summary': summary,
    'projects': [
      for (final project in rows.take(10))
        {
          'folder': project.cwd != '?'
              ? tilde(project.cwd)
              : tr('Unknown folder'),
          'text': [
            tr(
              '{0} working',
            ).replaceAll('{0}', durationText(project.active, tr)),
            count('1 session', '{0} sessions', project.sessions),
            tr('{0} tokens').replaceAll('{0}', shortNumber(project.tokens)),
            if (project.subagentRuns > 0)
              count(
                '1 subagent run',
                '{0} subagent runs',
                project.subagentRuns,
              ),
            if (project.linesAdded > 0 || project.linesRemoved > 0)
              tr('+{0} −{1} lines')
                  .replaceAll('{0}', '${project.linesAdded}')
                  .replaceAll('{1}', '${project.linesRemoved}'),
            if (project.cost != 0)
              tr(
                'API value {0}',
              ).replaceAll('{0}', '\$ ${pyFixedExact(project.cost, 2)}'),
          ].join(' · '),
        },
    ],
    if (runs.isNotEmpty) 'subagents_title': tr('Subagents, last 30 days'),
    'subagents': [
      for (final (kind, n, tokens, active) in runs.take(10))
        {
          'kind': kind != '?' ? kind : tr('Unknown type'),
          'text': [
            count('1 run', '{0} runs', n),
            tr('{0} tokens').replaceAll('{0}', shortNumber(tokens)),
            tr('{0} working').replaceAll('{0}', durationText(active, tr)),
          ].join(' · '),
        },
    ],
    'notes': [
      if (peak != null)
        tr('Most active: {0}, around {1}:00')
            .replaceAll('{0}', tr(_weekdays[peak.$1]))
            .replaceAll('{1}', '${peak.$2}'),
      if (note.isNotEmpty) note,
    ],
  };
}
