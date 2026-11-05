import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'first_agent.dart' show credentialsPresent;
import 'posix_ffi.dart';
import 'py_values.dart' show pyFixedExact, pyRound;
import 'adapter_assets.g.dart';

/// plugin_costs (currency, text, the euro rate) and agent_status
/// (pays_per_token) for an agent's cost card: what its tokens cost at API
/// prices, "API cost" for one paid per token, "API value" for one on a plan.

const ecbUrl = 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml';
const rateEvery = 24 * 3600, rateMaxBytes = 64 * 1024;

/// The euro rate is kept for all of Uwe's plugins in one shared file.
String rateFile(String home) =>
    p.join(home, '.local/state/omarchy-plugin-ai/exchange-rate.json');

/// plugin_costs.in_currency: euros when asked and a rate is known.
(double, String) inCurrency(double usd, String currency, double? usdPerEur) =>
    currency == 'eur' && usdPerEur != null && usdPerEur != 0
    ? (usd / usdPerEur, 'eur')
    : (usd, 'usd');

String _grouped(String digits) {
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// Python's f"{x:,.0f}" / f"{x:,.2f}" (round half to even as Python does
/// for the float's exact value).
String _format(double amount, int places) {
  final text = pyFixedExact(amount, places);
  final parts = text.split('.');
  return parts.length == 1
      ? _grouped(parts[0])
      : '${_grouped(parts[0])}.${parts[1]}';
}

/// plugin_costs.cost_text: $3.40, $123, <$0.01; in euros 3.03 €, 110 €.
String costText(double usd, String currency, double? usdPerEur) {
  final (amount, shown) = inCurrency(usd, currency, usdPerEur);
  final number = amount < 0.01
      ? '<0.01'
      : amount >= 100
      ? _format(amount, 0)
      : _format(amount, 2);
  if (shown == 'eur') return '$number €';
  return number == '<0.01' ? r'<$0.01' : '\$$number';
}

/// ui_helpers.short_number: 36835328 → "36.8M".
String shortNumber(int n) {
  for (final (size, suffix) in [
    (1000000000, 'B'),
    (1000000, 'M'),
    (1000, 'k'),
  ]) {
    if (n >= size) {
      var text = (n / size).toStringAsFixed(1);
      text = text
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
      return '$text$suffix';
    }
  }
  return '$n';
}

final _rateRe = RegExp(
  r'''currency=['"]USD['"]\s+rate=['"]([0-9]{1,2}\.[0-9]{1,6})['"]''',
);
final _dayRe = RegExp(r'''time=['"]([0-9]{4}-[0-9]{2}-[0-9]{2})['"]''');

/// plugin_costs.parse_ecb: (US dollars per euro, the rate's day), only a
/// plausible one.
(double, String)? parseEcb(List<int> body) {
  final text = utf8.decode(
    body.length > rateMaxBytes ? body.sublist(0, rateMaxBytes) : body,
    allowMalformed: true,
  );
  final found = _rateRe.firstMatch(text);
  if (found == null) return null;
  final rate = double.parse(found[1]!);
  final day = _dayRe.firstMatch(text);
  return rate > 0.5 && rate < 3 ? (rate, day?[1] ?? '') : null;
}

/// plugin_costs._kept: the kept rate, when it is a plausible one.
Map<String, dynamic> keptRate(String path, [Posix? posix]) {
  try {
    final data = jsonDecode(
      utf8.decode((posix ?? Posix()).readRegular(path, 4096)),
    );
    if (data is! Map<String, dynamic>) return {};
    final rate = data['usd_per_eur'];
    final ok = rate is num && rate > 0.5 && rate < 3;
    return ok && data['fetched'] is num ? data : {};
  } on Object {
    return {};
  }
}

/// plugin_costs.usd_per_eur: the kept rate while it is less than a day old;
/// else a fresh one through [fetch], kept; else the last kept one.
Future<(double, String)?> usdPerEur(
  Future<List<int>> Function(String url)? fetch,
  String path, {
  double? now,
  Posix? posix,
}) async {
  final at = now ?? DateTime.now().millisecondsSinceEpoch / 1000;
  final kept = keptRate(path, posix);
  (double, String)? fromKept() => kept.isEmpty
      ? null
      : ((kept['usd_per_eur'] as num).toDouble(), '${kept['day'] ?? ''}');
  if (kept.isNotEmpty && at - (kept['fetched'] as num) < rateEvery) {
    return fromKept();
  }
  (double, String)? found;
  if (fetch != null) {
    try {
      found = parseEcb(await fetch(ecbUrl));
    } on Object {
      found = null; // no network, a refused answer: the last rate kept
    }
  }
  if (found == null) return fromKept();
  try {
    final folder = p.dirname(path);
    if (!Directory(folder).existsSync()) {
      Directory(folder).createSync(recursive: true);
      (posix ?? Posix()).chmodPath(folder, 0x1c0);
    }
    (posix ?? Posix()).atomicWrite(
      path,
      utf8.encode(
        jsonEncode({'usd_per_eur': found.$1, 'day': found.$2, 'fetched': at}),
      ),
    );
  } on Object {
    // not kept: fetched again next time
  }
  return found;
}

const _turnedDown = {'Waiting for auth', 'Sign-in expired'};

/// agent_status.pays_per_token: paid per token (an API key or API billing)
/// rather than with a plan whose limits the battery shows. [billed]: its
/// sessions of the last 30 days say they cost money (UsageReaders.costs'
/// `billed`, from the agent's own store), which a provider billing per
/// token sets and a plan or a local LLM does not.
bool paysPerToken({
  required List limits,
  required String plan,
  required Map usageRecord,
  required Map access,
  required String home,
  required Map<String, String> environment,
  bool billed = false,
}) {
  final note = '${usageRecord['usageStatusText'] ?? ''}'.trim();
  if (limits.isNotEmpty || _turnedDown.contains(note)) return false;
  if (access.isNotEmpty) {
    for (final name in access['env'] as List? ?? const []) {
      if ((environment['$name'] ?? '').isNotEmpty) return true;
    }
    if (access['per_token'] == true &&
        credentialsPresent(access, home, environment)) {
      return true;
    }
  }
  final hasUsage =
      usageRecord['ready'] == true || usageRecord['hasLocalStats'] == true;
  return (hasUsage || billed) && plan.isEmpty;
}

/// details_pages.fill_cost_card: the card's texts, from costs (null: none
/// known) and how it is paid.
Map<String, dynamic>? costCard({
  required Map<String, dynamic>? spent,
  required String name,
  required bool installed,
  required bool hasSessions,
  required bool paying,
  required String plan,
  required String currency,
  required num limit,
  required double? usdPerEur,
  required String Function(String) tr,
}) {
  if (spent == null) {
    if (!installed || hasSessions) return null;
    return {
      'title': tr('API cost'),
      'summary': tr('not known'),
      'tiles': <dynamic>[],
      'models': <dynamic>[],
      'notes': [
        tr(
          '{0} keeps no token counts on this PC that the app can read, so what it costs is not shown here. Its provider\'s own account page has it.',
        ).replaceAll('{0}', name),
      ],
    };
  }
  String money(num usd) => costText(usd.toDouble(), currency, usdPerEur);
  final today = (spent['today'] as num).toDouble();
  var todayNote = '';
  if (paying) {
    final share = limit != 0
        ? inCurrency(today, currency, usdPerEur).$1 / limit
        : 0.0;
    todayNote = tr(
      "{0} % of the day's limit",
    ).replaceAll('{0}', '${pyRound(share * 100)}');
  } else if (plan.isNotEmpty) {
    todayNote = tr('covered by your {0} plan').replaceAll('{0}', plan);
  }
  final kinds = [
    tr('Input'),
    tr('Output'),
    tr('Cache read'),
    tr('Cache write'),
  ];
  final byModel = (spent['by_model'] as Map).entries.toList();
  double sumOf(List v) =>
      v.fold<double>(0, (s, x) => s + (x as num).toDouble());
  byModel.sort(
    (a, b) => sumOf(
      (b.value as List)[2] as List,
    ).compareTo(sumOf((a.value as List)[2] as List)),
  );
  final notes = <String>[];
  final reported = (spent['reported'] as num).toDouble();
  if (reported > 0) {
    notes.add(
      tr(
        '{0} in 30 days as the agent itself reports it (it keeps no token counts to split).',
      ).replaceAll('{0}', money(reported)),
    );
  }
  final unpriced = (spent['unpriced'] as Map).entries.toList()
    ..sort((a, b) => (b.value as int).compareTo(a.value as int));
  if (unpriced.isNotEmpty) {
    notes.add(
      tr(
        'No API cost: {0} (tokens of models without a price, such as local LLMs).',
      ).replaceAll(
        '{0}',
        [
          for (final e in unpriced.take(4))
            '${e.key} (${shortNumber(e.value as int)})',
        ].join(', '),
      ),
    );
  }
  final asOf = providerFacts['prices_as_of'] as Map? ?? const {};
  final dates = {for (final m in byModel) '${asOf[(m.value as List)[0]] ?? ''}'}
    ..remove('');
  notes.add(
    tr(
          "An estimate: the tokens of its sessions (counted on the day of their last reply) at the providers' API prices as of {0}.",
        ).replaceAll('{0}', (dates.toList()..sort()).join(', ')) +
        (plan.isNotEmpty && !paying
            ? ' ${tr('Not what a plan costs: the plan covers it.')}'
            : ''),
  );
  return {
    'title': tr(paying ? 'API cost' : 'API value'),
    'summary': [
      tr('{0} today').replaceAll('{0}', money(today)),
      tr('{0} in 7 days').replaceAll('{0}', money(spent['week'] as num)),
    ].join(' · '),
    'paying': paying,
    'tiles': [
      [tr('Today'), money(today), todayNote],
      [tr('Last 7 days'), money(spent['week'] as num), ''],
      [tr('Last 30 days'), money(spent['month'] as num), ''],
    ],
    'models': [
      for (final m in byModel.take(6))
        () {
          final value = m.value as List;
          final counts = value[1] as List, parts = value[2] as List;
          return {
            'heading': tr('{0}, last 30 days').replaceAll('{0}', m.key),
            'rows': [
              for (var i = 0; i < 4; i++)
                if ((counts[i] as num) != 0)
                  [
                    kinds[i],
                    tr('{0} tokens · {1}')
                        .replaceAll(
                          '{0}',
                          shortNumber((counts[i] as num).toInt()),
                        )
                        .replaceAll('{1}', money(parts[i] as num)),
                  ],
              [tr('In all'), money(sumOf(parts))],
            ],
          };
        }(),
    ],
    'notes': notes,
  };
}
