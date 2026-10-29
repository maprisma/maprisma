import 'dart:convert';
import 'dart:io';
import 'desktop.dart' show whichIn;

/// The red-limit notification (ai_popup.warn_red, Settings › Costs): an
/// agent's plan limit used up to the red level gets one desktop
/// notification per limit and reset; what was shown is kept, so a restart
/// does not show it again.

const batteryLow = 0.25, batteryEmpty = 0.10;

/// agent_details.warn_levels: (yellow, red) as shares used.
(double, double) warnLevels(dynamic yellow, dynamic red) {
  final y = (yellow is int ? yellow : 75) / 100,
      r = (red is int ? red : 90) / 100;
  return r > y ? (y, r) : (1 - batteryLow, 1 - batteryEmpty);
}

double _round4(double x) => (x * 10000).round() / 10000;

/// agent_details.red_limits: limits still counting, used up to the red level.
List<Map> redLimits(List<Map> limits, double red, DateTime now) => [
  for (final l in limits)
    if ((l['resets_at'] == null ||
            DateTime.tryParse('${l['resets_at']}')?.isAfter(now) != false) &&
        _round4((l['percent'] as num).toDouble()) >= red)
      l,
];

final _notPlain = RegExp('[<>&\\x00-\\x1f\\x7f-\\x9f]');

/// ai_core.plain_text: markup and control characters out, white space
/// folded, the length capped.
String plainText(dynamic text, [int most = 200]) {
  final folded = '${text ?? ''}'
      .replaceAll('\n', ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ')
      .replaceAll(_notPlain, '');
  final runes = folded.runes.toList();
  return runes.length <= most
      ? folded
      : '${String.fromCharCodes(runes.take(most - 1)).trimRight()}…';
}

String _clock(DateTime local) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  String two(int n) => '$n'.padLeft(2, '0');
  return '${days[local.weekday - 1]} ${two(local.hour)}:${two(local.minute)}';
}

final class RedLimits {
  RedLimits(this.path, {this.searchPath, this.send});
  final String path;
  final String? searchPath;

  /// Sends one notification (title, body); default notify-send.
  final bool Function(String title, String body)? send;

  Map<String, dynamic> _shown() {
    try {
      final data = jsonDecode(File(path).readAsStringSync());
      return data is Map<String, dynamic> ? data : {};
    } on Object {
      return {};
    }
  }

  bool _notifySend(String title, String body) {
    final program = whichIn('notify-send', searchPath);
    if (program == null) return false;
    try {
      return Process.runSync(program, [
            '--app-name=Asterism',
            '--',
            title,
            body,
          ]).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  /// For each agent (command → (name, limits)): its red limits not shown yet,
  /// each shown once; the notifications sent.
  List<Map<String, String>> check(
    Map<String, (String, List<Map>)> agents,
    double red,
    DateTime now,
    String Function(String) tr,
    void Function(String path, List<int> bytes) write,
  ) {
    final sent = <Map<String, String>>[];
    final today = now.toLocal();
    String day(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';
    for (final e in agents.entries) {
      for (final limit in redLimits(e.value.$2, red, now)) {
        final resets = limit['resets_at'] == null
            ? null
            : DateTime.tryParse('${limit['resets_at']}');
        final stamp = resets?.toUtc().toIso8601String() ?? day(today);
        final label = '${limit['label'] ?? ''}';
        final key = 'limit:${e.key}:$label:$stamp';
        var shown = _shown();
        if (shown.containsKey(key)) continue;
        final since = day(today.subtract(const Duration(days: 8)));
        shown = {
          for (final s in shown.entries)
            if (s.value is String && (s.value as String).compareTo(since) >= 0)
              s.key: s.value,
        };
        shown[key] = day(today);
        try {
          write(
            path,
            utf8.encode(
              '${const JsonEncoder.withIndent(' ').convert(shown)}\n',
            ),
          );
        } on Object {
          continue; // not kept: rather no notification than one at every look
        }
        var body = tr('{0}: {1} % used')
            .replaceAll('{0}', label.isNotEmpty ? label : tr('Limit'))
            .replaceAll('{1}', '${((limit['percent'] as num) * 100).round()}');
        if (resets != null) {
          body +=
              ', ${tr('resets {0}').replaceAll('{0}', _clock(resets.toLocal()))}';
        }
        final title = plainText(
          tr('{0} is in the red').replaceAll('{0}', e.value.$1),
          80,
        );
        final text = plainText(body, 300);
        if ((send ?? _notifySend)(title, text)) {
          sent.add({'title': title, 'body': text});
        }
      }
    }
    return sent;
  }
}
