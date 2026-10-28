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
