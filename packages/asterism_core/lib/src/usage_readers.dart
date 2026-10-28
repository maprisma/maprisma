import 'adapter_assets.g.dart';
import 'adapters.dart';
import 'scan_files.dart';
import 'session_readers.dart';

int usageNumber(dynamic value) {
  if (value is bool) return value ? 1 : 0;
  final number = value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  return number < 0 ? 0 : number;
}

double compensatedSum(Iterable<double> values) {
  var sum = 0.0, error = 0.0;
  for (final value in values) {
    final next = sum + value;
    error += sum.abs() >= value.abs()
        ? (sum - next) + value
        : (value - next) + sum;
    sum = next;
  }
  return sum + error;
}

final class UsageReaders {
  UsageReaders(this.files) : sessions = SessionReaders(files);
  final ScanFiles files;
  final SessionReaders sessions;
  DateTime get today {
    final time = DateTime.fromMicrosecondsSinceEpoch(
      (scanNow(files) * 1e6).round(),
    );
    return DateTime(time.year, time.month, time.day);
  }

  String day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  DateTime? date(double? value) {
    if (value == null || !value.isFinite || value.abs() > 8e12) return null;
    final t = DateTime.fromMicrosecondsSinceEpoch((value * 1e6).round());
    return DateTime(t.year, t.month, t.day);
  }

  Map<String, dynamic>? costs(
    Adapter adapter, {
    Map<String, NumericSession>? collected,
  }) {
    if (adapter.table('sessions').isEmpty) return null;
    final found = collected ?? sessions.read(adapter),
        models = <String, dynamic>{},
        unknown = <String, int>{};
    final prices = providerFacts['prices'] as Map;
    var total = 0.0, week = 0.0, current = 0.0, reported = 0.0, any = false;
    for (final session in found.values) {
      final d = date(session.last != 0 ? session.last : session.first);
      if (d == null) continue;
      final age = today.difference(d).inDays;
      if (age < 0 || age >= 30) continue;
      for (final entry in session.tokens.entries) {
        final model = entry.key.trim().toLowerCase().split('/').last;
        final keys = prices.keys.cast<String>().where(model.startsWith).toList()
          ..sort((a, b) => b.length.compareTo(a.length));
        if (keys.isEmpty) {
          final n = entry.value.fold<int>(0, (n, v) => n + usageNumber(v));
          if (entry.key.isNotEmpty && n > 0) {
            unknown[entry.key] = (unknown[entry.key] ?? 0) + n;
          }
          continue;
        }
        final price = prices[keys.first] as List;
        final amounts = [
          for (var i = 0; i < 4; i++)
            entry.value[i] * (price[i + 1] as num) / 1000000,
        ];
        final kept =
            models.putIfAbsent(
                  entry.key,
                  () => [
                    price[0],
                    [0, 0, 0, 0],
                    [0.0, 0.0, 0.0, 0.0],
                  ],
                )
                as List;
        for (var i = 0; i < 4; i++) {
          kept[1][i] += entry.value[i];
          kept[2][i] += amounts[i];
        }
        final spent = compensatedSum(amounts);
        total += spent;
        if (age < 7) week += spent;
        if (age == 0) current += spent;
        any = true;
      }
      if (session.tokens.isEmpty && session.cost > 0) {
        reported += session.cost;
        total += session.cost;
        if (age < 7) week += session.cost;
        if (age == 0) current += session.cost;
        any = true;
      }
    }
    return any
        ? {
            'today': current,
            'week': week,
            'month': total,
            'by_model': models,
            'unpriced': unknown,
            'reported': reported,
          }
        : null;
  }

  Map<String, dynamic>? fromSessions(
    Map<String, NumericSession> found,
    String source,
  ) {
    if (found.isEmpty) return null;
    final start = today.subtract(const Duration(days: 6)),
        days = <String, int>{},
        models = <String, List<int>>{};
    var total = 0, week = 0, todaySessions = 0, money = 0.0, todayMoney = 0.0;
    DateTime? last;
    for (final session in found.values) {
      final stamp = session.last != 0 ? session.last : session.first,
          d = date(stamp);
      if (d == null) continue;
      total++;
      if (!d.isBefore(start)) week++;
      if (d == today) todaySessions++;
      if (last == null || stamp > last.microsecondsSinceEpoch / 1e6) {
        last = DateTime.fromMicrosecondsSinceEpoch((stamp * 1e6).round());
      }
      money += session.cost;
      if (d == today) todayMoney += session.cost;
      for (final e in session.tokens.entries) {
        final c = e.value;
        final counts = models.putIfAbsent(e.key, () => [0, 0, 0]);
        counts[0] += c[0];
        counts[1] += c[1];
        counts[2] += c[3];
        if (!d.isBefore(start)) {
          days[day(d)] = (days[day(d)] ?? 0) + c[0] + c[1] + c[3];
        }
      }
    }
    models.removeWhere((k, c) => c.every((n) => n == 0));
    return {
      'days': [
        for (var i = 0; i < 7; i++)
          [
            day(start.add(Duration(days: i))),
            days[day(start.add(Duration(days: i)))] ?? 0,
          ],
      ],
      'by_model': models,
      'sessions_week': week,
      'sessions_total': total,
      'sessions_today': todaySessions,
      'prompts_today': null,
      'last': last?.toIso8601String().replaceFirst(RegExp(r'\.000$'), ''),
      'cost': money == 0 ? null : money,
      'cost_today': money == 0 ? null : todayMoney,
      'source': source,
      'has_tokens': true,
      'api_value': true,
    };
  }
}
