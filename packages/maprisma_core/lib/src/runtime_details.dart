import 'costs.dart' show shortNumber;
import 'py_values.dart' show pyFixedExact;
import 'session_readers.dart' show NumericSession;

/// A local LLM's details page (details_pages.open_runtime_status and
/// fill_usage_card for a local LLM, agent_status.runtime_usage,
/// agent_security.runtime_report): whether it runs and what it holds on the
/// GPU, its models, agents and address, what agents sent through it, and who
/// can reach it.

const _days = 7;

/// agent_status.model_key: comparable model names.
String runtimeModelKey(String name) {
  var text = name.trim().split('/').last.split(':').first.toLowerCase();
  for (final ending in ['.gguf', '.kcpps']) {
    if (text.endsWith(ending)) {
      text = text.substring(0, text.length - ending.length);
    }
  }
  return text;
}

DateTime _day(double epoch) {
  final t = DateTime.fromMicrosecondsSinceEpoch((epoch * 1e6).round());
  return DateTime(t.year, t.month, t.day);
}

/// agent_status.runtime_usage: the tokens agents sent through it, where a
/// session's model is one of the LLM's models; null without any.
Map<String, dynamic>? runtimeUsage(
  List<String> models,
  Map<String, List<NumericSession>> agentSessions,
  String connectKey,
  DateTime today,
) {
  final wanted = {for (final m in models) runtimeModelKey(m)}..remove('');
  if (wanted.isEmpty) return null;
  final rows = <(double, String, int, int, int)>[];
  final used = <double>[];
  for (final e in agentSessions.entries) {
    for (final s in e.value) {
      var hit = false;
      final when = s.last != 0 ? s.last : s.first;
      for (final t in s.tokens.entries) {
        final model = t.key;
        final prefix = model.contains('/')
            ? model.substring(0, model.lastIndexOf('/'))
            : '';
        if (prefix.isNotEmpty &&
            connectKey.isNotEmpty &&
            prefix != connectKey) {
          continue;
        }
        if (wanted.contains(runtimeModelKey(model))) {
          rows.add((
            when,
            '${e.key} · $model',
            t.value[0],
            t.value[1],
            t.value[3],
          ));
          hit = true;
        }
      }
      if (hit) used.add(when);
    }
  }
  if (rows.isEmpty) return null;
  final day0 = DateTime(today.year, today.month, today.day);
  final weekStart = day0.subtract(const Duration(days: _days - 1));
  final perDay = <DateTime, int>{};
  final byModel = <String, List<int>>{};
  for (final (stamp, model, inp, out, cache) in rows) {
    final d = _day(stamp);
    if (!d.isBefore(weekStart)) {
      perDay[d] = (perDay[d] ?? 0) + inp + out + cache;
    }
    final name = model.length > 80 ? model.substring(0, 80) : model;
    final n = byModel.putIfAbsent(name, () => [0, 0, 0]);
    n[0] += inp;
    n[1] += out;
    n[2] += cache;
  }
  final days = [
    for (var i = 0; i < _days; i++)
      () {
        final d = weekStart.add(Duration(days: i));
        return (d, perDay[d] ?? 0);
      }(),
  ];
  return {
    'days': days,
    'by_model': byModel,
    'sessions_total': used.length,
    'sessions_week': used.where((x) => !_day(x).isBefore(weekStart)).length,
    'sessions_today': used.where((x) => _day(x) == day0).length,
  };
}

const _loopback = {'127.0.0.1', 'localhost', '::1', '[::1]'};

/// agent_security.runtime_report: who can reach it and what it runs.
List<Map<String, String>> runtimeRisks(
  bool installed,
  String address,
  String Function(String) tr,
) {
  if (!installed) return [];
  final host = address.contains(':')
      ? address.substring(0, address.lastIndexOf(':'))
      : '';
  return [
    if (host.isNotEmpty && !_loopback.contains(host))
      {
        'level': 'high',
        'title': tr('Reachable from your network'),
        'text': tr(
          'It listens on {0}: other devices on your network can use it and see what is asked, without a password.',
        ).replaceAll('{0}', address),
        'step': tr(
          'Let it listen on 127.0.0.1 only (its host setting, e.g. OLLAMA_HOST=127.0.0.1 or --host 127.0.0.1).',
        ),
      }
    else if (host.isNotEmpty)
      {
        'level': 'ok',
        'title': tr('Only this PC can reach it'),
        'text': tr('It listens on {0}.').replaceAll('{0}', address),
        'step': '',
      },
    {
      'level': 'low',
      'title': tr('No password on the local API'),
      'text': tr(
        'Any program you run, and other users of this PC, can use it while it runs.',
      ),
      'step': tr(
        'Stop it when no agent needs it (Maprisma does that for connected agents).',
      ),
    },
    {
      'level': 'low',
      'title': tr('Models come from the web'),
      'text': tr(
        'A model file is data, but a crafted one can attack the program that loads it.',
      ),
      'step': tr(
        'Get GGUF models from known publishers and keep the local LLM up to date.',
      ),
    },
  ];
}

/// open_runtime_status' hero line, tiles and fill_usage_card for it.
Map<String, dynamic> runtimeDetails({
  required Map rt,
  required Map? use,
  required Map<String, String> agentNames,
  required Map<String, dynamic>? usage,
  required String Function(String) tr,
  required String Function(String, String, int) plural,
  required String Function(String) tilde,
}) {
  const gib = 1024 * 1024 * 1024;
  String sessions(int n) =>
      plural('1 session', '{0} sessions', n).replaceAll('{0}', '$n');
  String now;
  if (rt['running'] == true) {
    now = tr('Running');
    final vram = use?['vram'] as int? ?? 0;
    if (use != null && vram >= 64 * 1024 * 1024) {
      now +=
          ' · ${tr('{0} GB of GPU memory').replaceAll('{0}', pyFixedExact(vram / gib, 1))}';
    }
    final loaded = [
      for (final e in (use?['models'] as Map? ?? const {}).entries)
        if (e.value == 'loaded') '${e.key}',
    ];
    if (loaded.isNotEmpty) {
      now += ' · ${tr('loaded: {0}').replaceAll('{0}', loaded.join(', '))}';
    }
  } else {
    now = tr(rt['installed'] == true ? 'Not running' : 'Not installed');
  }
  final agents = [for (final a in rt['agents'] as List? ?? const []) '$a'];
  final models = rt['models'] as List? ?? const [];
  final tiles = [
    [tr('Models'), '${models.length}', tilde('${rt['models_dir'] ?? ''}')],
    [
      tr('Agents'),
      '${agents.length}',
      [for (final a in agents) agentNames[a] ?? a].join(', '),
    ],
    if ('${rt['address'] ?? ''}'.isNotEmpty)
      [tr('Address'), '${rt['address']}', '${rt['service'] ?? ''}'],
  ];
  Map<String, dynamic>? card;
  if (usage != null) {
    final days = usage['days'] as List;
    final week = days.fold<int>(0, (n, d) => n + (d as (DateTime, int)).$2);
    final today = days.isEmpty ? 0 : (days.last as (DateTime, int)).$2;
    final byModel =
        (usage['by_model'] as Map<String, List<int>>).entries.toList()..sort(
          (a, b) => (b.value[0] + b.value[1] + b.value[2]).compareTo(
            a.value[0] + a.value[1] + a.value[2],
          ),
        );
    card = {
      'title': tr('Usage and tokens'),
      'summary': [
        tr('through {0}').replaceAll('{0}', '${rt['name']}'),
        tr('{0} tokens in 7 days').replaceAll('{0}', shortNumber(week)),
        sessions(usage['sessions_week'] as int),
      ].join(' · '),
      'tiles': [
        [
          tr('Today'),
          tr('{0} tokens').replaceAll('{0}', shortNumber(today)),
          sessions(usage['sessions_today'] as int),
        ],
        [
          tr('Last 7 days'),
          tr('{0} tokens').replaceAll('{0}', shortNumber(week)),
          sessions(usage['sessions_week'] as int),
        ],
        [tr('In total'), sessions(usage['sessions_total'] as int), ''],
      ],
      'days': [
        for (final d in days.cast<(DateTime, int)>())
          [
            '${d.$1.year}-${'${d.$1.month}'.padLeft(2, '0')}-${'${d.$1.day}'.padLeft(2, '0')}',
            d.$2,
          ],
      ],
      'models_title': tr('Tokens by agent and model'),
      'models': [
        for (final m in byModel.take(8))
          [
            m.key,
            tr('{0} in · {1} out · {2} cache')
                .replaceAll('{0}', shortNumber(m.value[0]))
                .replaceAll('{1}', shortNumber(m.value[1]))
                .replaceAll('{2}', shortNumber(m.value[2])),
          ],
      ],
      'note': tr(
        'What your agents sent through it, from their own session records (numbers only; matched by model name)',
      ),
    };
  }
  return {'now': now, 'tiles': tiles, 'usage': card};
}
