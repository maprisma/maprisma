/// Python's float timestamps and datetime text, so Dart replies match the reference.
library;

/// os.stat().st_mtime: CPython builds it as sec + nsec * 1e-9 in a double.
double pyTimestamp(int sec, int nsec) => sec + nsec * 1e-9;

double _halfEven(double x) {
  final rounded = x.roundToDouble();
  return (x - rounded).abs() == 0.5 ? 2.0 * (x / 2.0).roundToDouble() : rounded;
}

/// datetime.fromtimestamp(t): microseconds rounded half to even.
DateTime pyFromTimestamp(double t) {
  final whole = t.truncateToDouble();
  var micros = _halfEven((t - whole) * 1e6);
  var seconds = whole;
  if (micros >= 1e6) {
    seconds += 1;
    micros -= 1e6;
  } else if (micros < 0) {
    seconds -= 1;
    micros += 1e6;
  }
  return DateTime.fromMicrosecondsSinceEpoch(
    seconds.toInt() * 1000000 + micros.toInt(),
  );
}

String _two(int n) => n.toString().padLeft(2, '0');

/// datetime.isoformat() of a naive local time: microseconds only when not 0.
String pyIsoLocal(DateTime time) {
  final t = time.toLocal();
  final micros = t.millisecond * 1000 + t.microsecond;
  final base =
      '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
  return micros == 0 ? base : '$base.${micros.toString().padLeft(6, '0')}';
}

/// datetime.fromisoformat (Python 3.11+) for calendar dates, as a naive local
/// time: an offset is converted to local time. Week dates are not accepted.
DateTime? pyFromIsoformat(String text) {
  final digits = RegExp(r'^\d+$');
  String date, rest;
  if (text.length >= 10 && text[4] == '-' && text[7] == '-') {
    date = text.substring(0, 4) + text.substring(5, 7) + text.substring(8, 10);
    rest = text.substring(10);
  } else if (text.length >= 8 && digits.hasMatch(text.substring(0, 8))) {
    date = text.substring(0, 8);
    rest = text.substring(8);
  } else {
    return null;
  }
  if (!digits.hasMatch(date)) return null;
  final year = int.parse(date.substring(0, 4)),
      month = int.parse(date.substring(4, 6)),
      day = int.parse(date.substring(6, 8));
  if (year < 1 || month < 1 || month > 12 || day < 1) return null;
  final days = DateTime.utc(year, month + 1, 0).day;
  if (day > days) return null;
  var hour = 0, minute = 0, second = 0, micro = 0;
  int? offset; // seconds east of UTC
  if (rest.isNotEmpty) {
    var time = String.fromCharCodes(rest.runes.skip(1));
    if (time.isEmpty) return null;
    final zone = RegExp(r'[Z+-]').firstMatch(time);
    if (zone != null) {
      final tz = time.substring(zone.start);
      time = time.substring(0, zone.start);
      if (tz == 'Z') {
        offset = 0;
      } else {
        final m = RegExp(
          r'^([+-])(\d{2})(?:(:?)(\d{2})(?:\3(\d{2})(?:\.(\d{6}))?)?)?$',
        ).firstMatch(tz);
        if (m == null) return null;
        final h = int.parse(m[2]!), mm = int.parse(m[4] ?? '0');
        final ss = int.parse(m[5] ?? '0');
        if (h > 23 || mm > 59 || ss > 59) return null;
        offset = (m[1] == '-' ? -1 : 1) * (h * 3600 + mm * 60 + ss);
      }
    }
    final m = RegExp(
      r'^(\d{2})(?:(:?)(\d{2})(?:\2(\d{2})(?:[.,](\d+))?)?)?$',
    ).firstMatch(time);
    if (m == null) return null;
    hour = int.parse(m[1]!);
    minute = int.parse(m[3] ?? '0');
    second = int.parse(m[4] ?? '0');
    final fraction = m[5] ?? '';
    if (fraction.isNotEmpty) {
      micro = int.parse(fraction.padRight(6, '0').substring(0, 6));
    }
    if (minute > 59 || second > 59) return null;
    if (hour == 24) {
      if (minute != 0 || second != 0 || micro != 0) return null;
    } else if (hour > 23) {
      return null;
    }
  }
  final base = DateTime.utc(year, month, day, hour, minute, second, 0, micro);
  if (offset == null) {
    return DateTime(year, month, day, hour, minute, second, 0, micro);
  }
  return base.subtract(Duration(seconds: offset)).toLocal();
}
