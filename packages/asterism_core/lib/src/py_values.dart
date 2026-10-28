import 'dart:convert';

/// Python's str() of a JSON value, for fields the reference passes through str().
String pyStr(dynamic v) => switch (v) {
  null => 'None',
  true => 'True',
  false => 'False',
  String s => s,
  int i => '$i',
  double d =>
    d == d.truncateToDouble() && d.abs() < 1e16 ? '${d.toInt()}.0' : '$d',
  _ => jsonEncode(v),
};

/// Python's bool() of a JSON value.
bool pyTruthy(dynamic v) => switch (v) {
  null || false => false,
  num n => n != 0,
  String s => s.isNotEmpty,
  List l => l.isNotEmpty,
  Map m => m.isNotEmpty,
  _ => true,
};

/// Python orders str by code point; Dart's compareTo by UTF-16 unit.
int pyCompare(String a, String b) {
  final x = a.runes.toList(), y = b.runes.toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] != y[i]) return x[i] - y[i];
  }
  return x.length - y.length;
}

/// json.dumps(value) with its defaults: ", " and ": " separators, ASCII only.
String pyJsonDumps(dynamic value) {
  final out = StringBuffer();
  void write(dynamic v) {
    if (v is String) {
      out.write('"');
      for (final unit in v.codeUnits) {
        switch (unit) {
          case 0x22:
            out.write(r'\"');
          case 0x5c:
            out.write(r'\\');
          case 0x0a:
            out.write(r'\n');
          case 0x0d:
            out.write(r'\r');
          case 0x09:
            out.write(r'\t');
          case 0x08:
            out.write(r'\b');
          case 0x0c:
            out.write(r'\f');
          default:
            if (unit < 0x20 || unit > 0x7e) {
              out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
            } else {
              out.writeCharCode(unit);
            }
        }
      }
      out.write('"');
    } else if (v is List) {
      out.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) out.write(', ');
        write(v[i]);
      }
      out.write(']');
    } else if (v is Map) {
      out.write('{');
      var first = true;
      for (final e in v.entries) {
        if (!first) out.write(', ');
        first = false;
        write('${e.key}');
        out.write(': ');
        write(e.value);
      }
      out.write('}');
    } else {
      out.write(v == null ? 'null' : '$v');
    }
  }

  write(value);
  return out.toString();
}
