import 'package:flutter/material.dart';

import 'app_look.dart';

/// A project's recurring run (task 101): the choices of `set_schedule`.
enum ScheduleRepeat {
  off(null, 'Off'),
  daily('daily', 'Every day'),
  weekdays('weekdays', 'On weekdays'),
  weekly('weekly', 'Every week'),
  hours('hours', 'Every few hours'),
  monthly('monthly', 'Every month');

  const ScheduleRepeat(this.code, this.label);

  /// The backend's `repeat`; null: no schedule.
  final String? code;
  final String label;

  static ScheduleRepeat of(Object? schedule) {
    final code = schedule is Map ? schedule['repeat'] : null;
    return values.firstWhere((r) => r.code == code, orElse: () => off);
  }
}

/// Short weekday names, ISO order (Monday 1).
const scheduleWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Every few hours: the steps the backend accepts (divisors of 24).
const scheduleHourSteps = [1, 2, 3, 4, 6, 8, 12];

String _two(int n) => n.toString().padLeft(2, '0');

String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// A local date the backend wrote (`YYYY-MM-DD`).
DateTime? _parseDate(Object? text) {
  if (text is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
  return m == null
      ? null
      : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

List<int> _days(Map schedule) => [
  for (final d in schedule['days'] as List? ?? const [])
    if (d is int && d >= 1 && d <= 7) d,
];

/// The next run, short: "Tue 05:00" within a week, else the date and time.
String scheduleNextShort(
  String nextRun,
  String Function(String) tr,
  MaterialLocalizations local, {
  DateTime? now,
}) {
  final at = DateTime.tryParse(nextRun)?.toLocal();
  if (at == null) return '';
  final time = '${_two(at.hour)}:${_two(at.minute)}';
  final today = now ?? DateTime.now();
  final days = DateTime(
    at.year,
    at.month,
    at.day,
  ).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days >= 0 && days < 7) {
    return '${tr(scheduleWeekdays[at.weekday - 1])} $time';
  }
  return '${local.formatShortMonthDay(at)} $time';
}

/// The schedule in one line: "Every day at 05:00 · next run Tue 05:00".
String scheduleSummary(
  Map schedule,
  String? nextRun,
  String Function(String) tr,
  MaterialLocalizations local, {
  DateTime? now,
}) {
  final time = '${schedule['time'] ?? ''}';
  final days = [for (final d in _days(schedule)) tr(scheduleWeekdays[d - 1])];
  final every = schedule['every'];
  final what = switch (ScheduleRepeat.of(schedule)) {
    ScheduleRepeat.daily => tr('Every day at {0}').replaceAll('{0}', time),
    ScheduleRepeat.weekdays => tr(
      'On {0} at {1}',
    ).replaceAll('{0}', days.join(', ')).replaceAll('{1}', time),
    ScheduleRepeat.weekly => tr(
      'Every week on {0} at {1}',
    ).replaceAll('{0}', days.join(', ')).replaceAll('{1}', time),
    ScheduleRepeat.hours =>
      every == 1
          ? tr('Every hour from {0}').replaceAll('{0}', time)
          : tr(
              'Every {0} hours from {1}',
            ).replaceAll('{0}', '$every').replaceAll('{1}', time),
    ScheduleRepeat.monthly => tr(
      'On day {0} of every month at {1}',
    ).replaceAll('{0}', '${schedule['day']}').replaceAll('{1}', time),
    ScheduleRepeat.off => tr('Off'),
  };
  final until = _parseDate(schedule['until']);
  return [
    what,
    if (until != null)
      tr('until {0}').replaceAll('{0}', local.formatMediumDate(until)),
    nextRun == null
        ? tr('The schedule has ended.')
        : tr(
            'next run {0}',
          ).replaceAll('{0}', scheduleNextShort(nextRun, tr, local, now: now)),
  ].join(' · ');
}

/// The Goal tab's schedule (task 101): the recurrence, its time, days and
/// end, and a summary line. Each change is sent at once ([onChanged] with
/// the new schedule, null for off); null [onChanged]: read only.
class ProjectScheduleControl extends StatelessWidget {
  const ProjectScheduleControl({
    super.key,
    required this.schedule,
    required this.nextRun,
    required this.tr,
    required this.onChanged,
    this.approved = true,
    this.pickTime,
    this.pickDate,
    this.now,
  });

  final Map<String, dynamic>? schedule;
  final String? nextRun;
  final String Function(String) tr;
  final ValueChanged<Map<String, dynamic>?>? onChanged;

  /// The plan and team are approved now: scheduled runs can start.
  final bool approved;

  /// The time and date pickers (tests replace them).
  final Future<TimeOfDay?> Function(BuildContext context, TimeOfDay initial)?
  pickTime;
  final Future<DateTime?> Function(BuildContext context, DateTime initial)?
  pickDate;
  final DateTime? now;

  DateTime get _today => now ?? DateTime.now();

  void _send(Map<String, dynamic>? value) => onChanged?.call(value);

  /// [repeat] chosen: the time stays, the other fields get a start.
  Map<String, dynamic>? _withRepeat(ScheduleRepeat repeat) {
    final code = repeat.code;
    if (code == null) return null;
    final old = schedule ?? const {};
    final days = _days(old);
    return {
      'repeat': code,
      'time': old['time'] is String ? old['time'] : '09:00',
      if (repeat == ScheduleRepeat.weekdays)
        'days': days.isEmpty ? [1, 2, 3, 4, 5] : days,
      if (repeat == ScheduleRepeat.weekly)
        'days': [days.isEmpty ? _today.weekday : days.first],
      if (repeat == ScheduleRepeat.hours)
        'every': old['every'] is int ? old['every'] : 4,
      if (repeat == ScheduleRepeat.monthly)
        'day': old['day'] is int ? old['day'] : _today.day,
      if (old['until'] is String) 'until': old['until'],
    };
  }

  Map<String, dynamic> _with(String key, Object? value) =>
      {...?schedule, key: value}
        ..removeWhere((k, v) => k == 'until' && v == null);

  Future<void> _chooseTime(BuildContext context) async {
    final parts = '${schedule?['time'] ?? '09:00'}'.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 9,
      minute: int.tryParse(parts.last) ?? 0,
    );
    final picked =
        await (pickTime ??
            (context, initial) => showTimePicker(
              context: context,
              initialTime: initial,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
            ))(context, initial);
    if (picked != null) {
      _send(_with('time', '${_two(picked.hour)}:${_two(picked.minute)}'));
    }
  }

  Future<void> _chooseUntil(BuildContext context) async {
    final today = DateTime(_today.year, _today.month, _today.day);
    final current = _parseDate(schedule?['until']);
    final initial = current != null && !current.isBefore(today)
        ? current
        : today.add(const Duration(days: 30));
    final picked =
        await (pickDate ??
            (context, initial) => showDatePicker(
              context: context,
              initialDate: initial,
              firstDate: today,
              lastDate: DateTime(today.year + 10, 12, 31),
            ))(context, initial);
    if (picked != null) _send(_with('until', _date(picked)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final local = MaterialLocalizations.of(context);
    final value = schedule;
    final repeat = ScheduleRepeat.of(value);
    final enabled = onChanged != null;
    final days = value == null ? const <int>[] : _days(value);
    final until = _parseDate(value?['until']);

    Widget dropdown<T>({
      required String key,
      required T current,
      required List<(T, String)> items,
      required ValueChanged<T> onPicked,
      String? label,
    }) => DropdownButton<T>(
      key: ValueKey(key),
      value: current,
      isDense: true,
      hint: label == null ? null : Text(label),
      items: [
        for (final (item, text) in items)
          DropdownMenuItem(value: item, child: Text(text)),
      ],
      onChanged: enabled
          ? (picked) {
              if (picked != null && picked != current) onPicked(picked);
            }
          : null,
    );

    final controls = <Widget>[
      if (value != null)
        OutlinedButton.icon(
          key: const ValueKey('schedule-time'),
          onPressed: enabled ? () => _chooseTime(context) : null,
          icon: const Icon(Icons.schedule, size: 18),
          label: Text('${value['time']}'),
        ),
      if (repeat == ScheduleRepeat.weekdays)
        for (var d = 1; d <= 7; d++)
          FilterChip(
            key: ValueKey('schedule-day-$d'),
            label: Text(tr(scheduleWeekdays[d - 1])),
            selected: days.contains(d),
            // At least one day stays chosen.
            onSelected: !enabled || (days.length == 1 && days.contains(d))
                ? null
                : (on) => _send(
                    _with('days', [
                      for (var x = 1; x <= 7; x++)
                        if (x == d ? on : days.contains(x)) x,
                    ]),
                  ),
          ),
      if (repeat == ScheduleRepeat.weekly)
        dropdown<int>(
          key: 'schedule-weekday',
          current: days.isEmpty ? 1 : days.first,
          items: [
            for (var d = 1; d <= 7; d++) (d, tr(scheduleWeekdays[d - 1])),
          ],
          onPicked: (d) => _send(_with('days', [d])),
        ),
      if (repeat == ScheduleRepeat.hours)
        dropdown<int>(
          key: 'schedule-every',
          current: value?['every'] is int ? value!['every'] as int : 4,
          items: [
            for (final n in scheduleHourSteps)
              (
                n,
                n == 1
                    ? tr('Every hour')
                    : tr('Every {0} hours').replaceAll('{0}', '$n'),
              ),
          ],
          onPicked: (n) => _send(_with('every', n)),
        ),
      if (repeat == ScheduleRepeat.monthly)
        dropdown<int>(
          key: 'schedule-month-day',
          current: value?['day'] is int ? value!['day'] as int : 1,
          items: [
            for (var d = 1; d <= 31; d++)
              (d, tr('Day {0}').replaceAll('{0}', '$d')),
          ],
          onPicked: (d) => _send(_with('day', d)),
        ),
      if (value != null) ...[
        dropdown<bool>(
          key: 'schedule-ends',
          current: until != null,
          items: [(false, tr('Never ends')), (true, tr('Ends on a date'))],
          onPicked: (dated) =>
              dated ? _chooseUntil(context) : _send(_with('until', null)),
        ),
        if (until != null)
          TextButton.icon(
            key: const ValueKey('schedule-until'),
            onPressed: enabled ? () => _chooseUntil(context) : null,
            icon: const Icon(Icons.event, size: 18),
            label: Text(local.formatMediumDate(until)),
          ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(tr('Schedule'))),
            const SizedBox(width: AppSpace.md),
            dropdown<ScheduleRepeat>(
              key: 'schedule-repeat',
              current: repeat,
              items: [for (final r in ScheduleRepeat.values) (r, tr(r.label))],
              onPicked: (r) => _send(_withRepeat(r)),
            ),
          ],
        ),
        if (controls.isNotEmpty) ...[
          const SizedBox(height: AppSpace.xs),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: controls,
          ),
        ],
        if (value != null) ...[
          const SizedBox(height: AppSpace.xs),
          Row(
            children: [
              Icon(
                Icons.schedule,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  scheduleSummary(value, nextRun, tr, local, now: now),
                  key: const ValueKey('schedule-summary'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          if (!approved)
            Text(
              tr(
                'Scheduled runs start only while the plan and team are approved.',
              ),
              key: const ValueKey('schedule-not-approved'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ],
    );
  }
}

/// A board card's clock (task 101): the next scheduled run, the schedule in
/// its tooltip.
class ScheduleBadge extends StatelessWidget {
  const ScheduleBadge({
    super.key,
    required this.schedule,
    required this.nextRun,
    required this.tr,
    this.now,
  });

  final Map schedule;
  final String nextRun;
  final String Function(String) tr;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final local = MaterialLocalizations.of(context);
    final short = scheduleNextShort(nextRun, tr, local, now: now);
    final label = tr('Next scheduled run: {0}').replaceAll('{0}', short);
    return Tooltip(
      message: scheduleSummary(schedule, nextRun, tr, local, now: now),
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Row(
          key: const ValueKey('card-schedule'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule, size: 14, color: colors.onSurfaceVariant),
            const SizedBox(width: AppSpace.xs),
            Text(
              short,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
