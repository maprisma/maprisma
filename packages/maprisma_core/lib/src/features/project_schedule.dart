/// A project's recurring run (task 101): validation, the next planned run,
/// the planned run a trigger belongs to, and systemd `OnCalendar` lines.
/// Times are wall-clock times of the local zone; [ScheduleZone] converts
/// them, so DST can be tested with a fake zone.
library;

import '../protocol.dart' show ServiceError;

/// The local time zone: wall-clock fields to an instant and back.
abstract interface class ScheduleZone {
  /// The instant of a local wall-clock time. A time the clock skips (the
  /// spring DST gap) is the instant the same minutes after the gap; a time
  /// the clock shows twice (autumn) is its first occurrence.
  DateTime instant(int year, int month, int day, int hour, int minute);

  /// The local wall-clock fields of [instant] (as a UTC [DateTime] whose
  /// fields are the local ones).
  DateTime wall(DateTime instant);
}

/// The process's own zone (Dart's local time, the TZ of the process).
final class LocalScheduleZone implements ScheduleZone {
  const LocalScheduleZone();
  @override
  DateTime instant(int year, int month, int day, int hour, int minute) {
    var local = DateTime(year, month, day, hour, minute);
    // A time in the spring gap: the platform may normalise it backwards;
    // the same minutes after the gap instead (as mktime does).
    if (local.hour != hour || local.minute != minute) {
      final later = DateTime(year, month, day, hour + 1, minute);
      if (later.isAfter(local)) local = later;
    }
    return local.toUtc();
  }

  @override
  DateTime wall(DateTime instant) {
    final l = instant.toLocal();
    return DateTime.utc(l.year, l.month, l.day, l.hour, l.minute, l.second);
  }
}

const scheduleRepeats = {'daily', 'weekdays', 'weekly', 'hours', 'monthly'};
const scheduleHourSteps = {1, 2, 3, 4, 6, 8, 12};
const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

final _timePattern = RegExp(r'^([01][0-9]|2[0-3]):([0-5][0-9])$');
final _datePattern = RegExp(r'^([0-9]{4})-([0-9]{2})-([0-9]{2})$');

/// A checked schedule in its stored form, or null for off. [today] is the
/// local date (an `until` before it is refused when [checkUntil]).
Map<String, dynamic>? checkSchedule(
  Object? value, {
  DateTime? today,
  bool checkUntil = true,
}) {
  if (value == null) return null;
  Never invalid() => throw ServiceError('project_schedule_invalid');
  if (value is! Map) invalid();
  final repeat = value['repeat'];
  if (repeat is! String || !scheduleRepeats.contains(repeat)) invalid();
  final allowed = {
    'repeat',
    'time',
    'until',
    if (repeat == 'weekdays' || repeat == 'weekly') 'days',
    if (repeat == 'hours') 'every',
    if (repeat == 'monthly') 'day',
  };
  if (value.keys.any((key) => key is! String || !allowed.contains(key))) {
    invalid();
  }
  final time = value['time'];
  if (time is! String || !_timePattern.hasMatch(time)) invalid();
  final result = <String, dynamic>{'repeat': repeat, 'time': time};
  if (repeat == 'weekdays' || repeat == 'weekly') {
    final days = value['days'];
    if (days is! List ||
        days.isEmpty ||
        days.length > 7 ||
        days.any((d) => d is! int || d < 1 || d > 7) ||
        days.toSet().length != days.length ||
        (repeat == 'weekly' && days.length != 1)) {
      invalid();
    }
    result['days'] = [...days.cast<int>()]..sort();
  }
  if (repeat == 'hours') {
    final every = value['every'];
    if (every is! int || !scheduleHourSteps.contains(every)) invalid();
    result['every'] = every;
  }
  if (repeat == 'monthly') {
    final day = value['day'];
    if (day is! int || day < 1 || day > 31) invalid();
    result['day'] = day;
  }
  final until = value['until'];
  if (until != null) {
    final date = until is String ? parseScheduleDate(until) : null;
    if (date == null) invalid();
    if (checkUntil && today != null) {
      final t = DateTime.utc(today.year, today.month, today.day);
      if (date.isBefore(t)) invalid();
    }
    result['until'] = until;
  }
  return result;
}

/// `YYYY-MM-DD` as a UTC date, or null when it is no real date.
DateTime? parseScheduleDate(String text) {
  final m = _datePattern.firstMatch(text);
  if (m == null) return null;
  final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
  if (y < 2000 || y > 9999 || mo < 1 || mo > 12 || d < 1) return null;
  if (d > daysInMonth(y, mo)) return null;
  return DateTime.utc(y, mo, d);
}

int daysInMonth(int year, int month) => DateTime.utc(year, month + 1, 0).day;

(int, int) _clock(Map<String, dynamic> schedule) {
  final m = _timePattern.firstMatch(schedule['time'] as String)!;
  return (int.parse(m[1]!), int.parse(m[2]!));
}

/// The wall-clock times (hour, minute) [schedule] plans on the local date
/// [date] (UTC fields), in order.
List<(int, int)> _timesOn(Map<String, dynamic> schedule, DateTime date) {
  final (hour, minute) = _clock(schedule);
  switch (schedule['repeat']) {
    case 'daily':
      return [(hour, minute)];
    case 'weekdays':
    case 'weekly':
      return (schedule['days'] as List).contains(date.weekday)
          ? [(hour, minute)]
          : const [];
    case 'hours':
      final every = schedule['every'] as int;
      return [for (var h = hour % every; h < 24; h += every) (h, minute)];
    case 'monthly':
      final wanted = schedule['day'] as int;
      final last = daysInMonth(date.year, date.month);
      return date.day == (wanted < last ? wanted : last)
          ? [(hour, minute)]
          : const [];
  }
  return const [];
}

DateTime? _until(Map<String, dynamic> schedule) {
  final until = schedule['until'];
  return until is String ? parseScheduleDate(until) : null;
}

/// The next planned run strictly after [after] (UTC), or null when the
/// schedule has ended (or is off).
DateTime? nextScheduledRun(
  Map<String, dynamic>? schedule,
  DateTime after, {
  ScheduleZone zone = const LocalScheduleZone(),
}) {
  if (schedule == null) return null;
  final until = _until(schedule);
  final start = zone.wall(after);
  // A day back covers a wall time the zone moved; 400 days cover every
  // repeat (a month's day, a weekday).
  for (var offset = -1; offset <= 400; offset++) {
    final date = DateTime.utc(start.year, start.month, start.day + offset);
    if (until != null && date.isAfter(until)) return null;
    for (final (h, m) in _timesOn(schedule, date)) {
      final at = zone.instant(date.year, date.month, date.day, h, m);
      if (at.isAfter(after)) return at;
    }
  }
  return null;
}

/// The planned run a trigger at [at] belongs to: the latest one at or
/// before it (also past the `until` day; the caller checks the end), or
/// null when there is none within 400 days.
DateTime? latestScheduledRun(
  Map<String, dynamic> schedule,
  DateTime at, {
  ScheduleZone zone = const LocalScheduleZone(),
}) {
  final start = zone.wall(at);
  for (var offset = 1; offset >= -400; offset--) {
    final date = DateTime.utc(start.year, start.month, start.day + offset);
    for (final (h, m) in _timesOn(schedule, date).reversed) {
      final instant = zone.instant(date.year, date.month, date.day, h, m);
      if (!instant.isAfter(at)) return instant;
    }
  }
  return null;
}

/// Whether the planned run [slot] lies after the schedule's last day.
bool scheduleEndedAt(
  Map<String, dynamic> schedule,
  DateTime slot, {
  ScheduleZone zone = const LocalScheduleZone(),
}) {
  final until = _until(schedule);
  if (until == null) return false;
  final w = zone.wall(slot);
  return DateTime.utc(w.year, w.month, w.day).isAfter(until);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// systemd `OnCalendar=` values (local time) for [schedule]; several for a
/// month's day that some months do not have (they run on their last day).
List<String> scheduleCalendar(Map<String, dynamic> schedule) {
  final (hour, minute) = _clock(schedule);
  final clock = '${_two(hour)}:${_two(minute)}:00';
  switch (schedule['repeat']) {
    case 'daily':
      return ['*-*-* $clock'];
    case 'weekdays':
    case 'weekly':
      final names = [
        for (final d in schedule['days'] as List) _weekdayNames[(d as int) - 1],
      ].join(',');
      return ['$names *-*-* $clock'];
    case 'hours':
      final every = schedule['every'] as int;
      return ['*-*-* ${_two(hour % every)}/$every:${_two(minute)}:00'];
    case 'monthly':
      final day = schedule['day'] as int;
      if (day <= 28) return ['*-*-${_two(day)} $clock'];
      // The shortest length of each month (February: 28).
      const shortest = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
      final full = [
        for (var m = 1; m <= 12; m++)
          if (shortest[m - 1] >= day) _two(m),
      ];
      final short = [
        for (var m = 1; m <= 12; m++)
          if (shortest[m - 1] < day) _two(m),
      ];
      return [
        if (full.isNotEmpty) '*-${full.join(',')}-${_two(day)} $clock',
        // `~01`: the month's last day (February 28 or 29).
        if (short.isNotEmpty) '*-${short.join(',')}~01 $clock',
      ];
  }
  throw ServiceError('project_schedule_invalid');
}

/// The schedule in plain English, for events and journal lines.
String describeSchedule(Map<String, dynamic> schedule) {
  final time = schedule['time'];
  final days = [
    for (final d in schedule['days'] as List? ?? const [])
      _weekdayNames[(d as int) - 1],
  ].join(', ');
  final text = switch (schedule['repeat']) {
    'daily' => 'every day at $time',
    'weekdays' => 'on $days at $time',
    'weekly' => 'every week on $days at $time',
    'hours' => 'every ${schedule['every']} hours from $time',
    'monthly' => 'on day ${schedule['day']} of every month at $time',
    _ => 'scheduled',
  };
  final until = schedule['until'];
  return until is String ? '$text until $until' : text;
}
