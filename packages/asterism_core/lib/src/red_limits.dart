import 'dart:convert';
import 'dart:io';
import 'desktop.dart' show whichIn;
import 'py_values.dart' show pyRound;

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

String clock(DateTime local) {
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
            '--app-name=Maprisma',
            '--',
            title,
            body,
          ]).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  static String day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';

  /// warn_red: one desktop notification for [key], unless it was shown
  /// already; what was shown is kept (entries older than eight days go).
  /// Null when it was shown before, could not be kept or not sent.
  Map<String, String>? once(
    String key,
    String title,
    String body,
    DateTime now,
    void Function(String path, List<int> bytes) write,
  ) {
    final today = now.toLocal();
    var shown = _shown();
    if (shown.containsKey(key)) return null;
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
        utf8.encode('${const JsonEncoder.withIndent(' ').convert(shown)}\n'),
      );
    } on Object {
      return null; // not kept: rather no notification than one at every look
    }
    final t = plainText(title, 80), b = plainText(body, 300);
    return (send ?? _notifySend)(t, b) ? {'title': t, 'body': b} : null;
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
    for (final e in agents.entries) {
      for (final limit in redLimits(e.value.$2, red, now)) {
        final resets = limit['resets_at'] == null
            ? null
            : DateTime.tryParse('${limit['resets_at']}');
        final stamp = resets?.toUtc().toIso8601String() ?? day(now.toLocal());
        final label = '${limit['label'] ?? ''}';
        var body = tr('{0}: {1} % used')
            .replaceAll('{0}', label.isNotEmpty ? label : tr('Limit'))
            .replaceAll(
              '{1}',
              '${pyRound((limit['percent'] as num).toDouble() * 100)}',
            );
        if (resets != null) {
          body +=
              ', ${tr('resets {0}').replaceAll('{0}', clock(resets.toLocal()))}';
        }
        final note = once(
          'limit:${e.key}:$label:$stamp',
          tr('{0} is in the red').replaceAll('{0}', e.value.$1),
          body,
          now,
          write,
        );
        if (note != null) sent.add(note);
      }
    }
    return sent;
  }
}
