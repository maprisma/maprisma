import 'costs.dart';
import 'py_values.dart' show pyFixedExact, pyRound;
import 'red_limits.dart' show clock;

/// The badge in an agent's map box (ai_popup.set_agent_battery /
/// update_costs, agent_details.battery and battery_tip): what is left of an
/// online agent's plan limits as a battery, or, for one paid per token,
/// today's cost against a day's limit; green, yellow or red at Settings ›
/// Costs' levels.

double _round4(double x) => (x * 10000).round() / 10000;

/// agent_details.current_limits: the limits whose numbers still count.
List<Map> currentLimits(List<Map> limits, DateTime now) => [
  for (final l in limits)
    if (l['resets_at'] == null ||
        DateTime.tryParse('${l['resets_at']}')?.isAfter(now) != false)
      l,
];

/// agent_details._charge: (left, colour) of the tightest limit.
(double, String) charge(double left, (double, double) levels) {
  final (yellow, red) = levels;
  left = _round4(left); // 1 - 0.90 is 0.0999…: exactly a tenth left is red
  return (
    left,
    left <= _round4(1 - red)
        ? 'red'
        : left <= _round4(1 - yellow)
        ? 'yellow'
        : 'green',
  );
}

/// agent_details.battery: null without limits still counting.
(double, String)? battery(
  List<Map> limits,
  (double, double) levels,
  DateTime now,
) {
  final lefts = [
    for (final l in currentLimits(limits, now))
      1 - (l['percent'] as num).toDouble().clamp(0.0, 1.0),
  ];
  if (lefts.isEmpty) return null;
  return charge(lefts.reduce((a, b) => a < b ? a : b), levels);
}

/// agent_details.battery_tip: one line per limit still counting.
String batteryTip(
  List<Map> limits,
  DateTime now,
  String Function(String) tr,
) => [
  for (final l in currentLimits(limits, now))
    () {
      final left = pyRound(
        100 * (1 - (l['percent'] as num).toDouble().clamp(0.0, 1.0)),
      );
      final label = '${l['label'] ?? ''}';
      var line = tr('{0}: {1} % left')
          .replaceAll('{0}', label.isNotEmpty ? label : tr('Limit'))
          .replaceAll('{1}', '$left');
      final resets = l['resets_at'] == null
          ? null
          : DateTime.tryParse('${l['resets_at']}');
      if (resets != null) {
        line +=
            ', ${tr('resets {0}').replaceAll('{0}', clock(resets.toLocal()))}';
      }
      return line;
    }(),
].join('\n');

/// plugin_costs.cost_colour with both levels given.
String costColour(
  double usd,
  num limit,
  String currency,
  double? usdPerEur,
  double yellow,
  double red,
) {
  final share = limit > 0
      ? inCurrency(usd, currency, usdPerEur).$1 / limit
      : 0.0;
  return share >= red
      ? 'red'
      : share >= yellow
      ? 'yellow'
      : 'green';
}

/// update_costs' label: (label, tooltip, colour) and, when red, the
/// notification's body.
Map<String, dynamic> costBadge(
  double usd,
  num limit,
  String currency,
  double? usdPerEur,
  (double, double) levels,
  String Function(String) tr,
) {
  final text = costText(usd, currency, usdPerEur);
  final limitText = costText(
    currency == 'eur' && usdPerEur != null
        ? limit * usdPerEur
        : limit.toDouble(),
    currency,
    usdPerEur,
  );
  final colour = costColour(
    usd,
    limit,
    currency,
    usdPerEur,
    levels.$1,
    levels.$2,
  );
  return {
    'kind': 'cost',
    'label': tr('{0} today').replaceAll('{0}', text),
    'tip':
        '${tr('Paid per token, with no plan limits: about {0} today at API prices (estimated from the tokens of its sessions active today).').replaceAll('{0}', text)}\n'
        '${tr("A day's limit: {0} (Settings › Costs).").replaceAll('{0}', limitText)}',
    'colour': colour,
    if (colour == 'red')
      'red_body': tr("About {0} today, {1} % of the day's limit ({2}).")
          .replaceAll('{0}', text)
          .replaceAll(
            '{1}',
            '${limit > 0 ? pyRound(100 * inCurrency(usd, currency, usdPerEur).$1 / limit) : 0}',
          )
          .replaceAll('{2}', limitText),
  };
}

/// agent_details.gpu_battery: a running local LLM's battery of the GPU
/// memory still free, with the limits' colours; null without a GPU.
Map<String, dynamic>? gpuBattery(
  int free,
  int total,
  int own,
  (double, double) levels,
  String Function(String) tr,
) {
  if (total <= 0) return null;
  const gib = 1024 * 1024 * 1024;
  var tip = tr('GPU memory: {0} of {1} GB free')
      .replaceAll('{0}', pyFixedExact((free < 0 ? 0 : free) / gib, 1))
      .replaceAll('{1}', pyFixedExact(total / gib, 1));
  if (own >= 64 * 1024 * 1024) {
    tip +=
        '\n${tr('This local LLM uses {0} GB').replaceAll('{0}', pyFixedExact(own / gib, 1))}';
  }
  final (left, colour) = charge((free / total).clamp(0.0, 1.0), levels);
  return {'kind': 'battery', 'left': left, 'colour': colour, 'tip': tip};
}
