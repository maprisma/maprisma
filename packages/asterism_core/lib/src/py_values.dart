import 'dart:typed_data';
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

/// Python's repr() of a float: shortest round-trip digits, exponent form
/// below 1e-4 and from 1e16 on (as "1e-05", "1e+16").
String pyFloat(double d) {
  if (d.isNaN) return 'NaN';
  if (d.isInfinite) return d > 0 ? 'Infinity' : '-Infinity';
  if (d == 0) return d.isNegative ? '-0.0' : '0.0';
  final sign = d < 0 ? '-' : '';
  // Shortest digits and decimal exponent from Dart's own shortest form.
  final text = d.abs().toStringAsExponential(); // e.g. "1.2345e-5"
  final mantissa = text.split('e')[0].replaceAll('.', '');
  final exponent = int.parse(text.split('e')[1]);
  final digits = mantissa.replaceFirst(RegExp(r'0+$'), '');
  final shortest = digits.isEmpty ? '0' : digits;
  if (exponent < -4 || exponent >= 16) {
    final m = shortest.length > 1
        ? '${shortest[0]}.${shortest.substring(1)}'
        : shortest;
    final e = exponent.abs().toString().padLeft(2, '0');
    return '$sign${m}e${exponent < 0 ? '-' : '+'}$e';
  }
  if (exponent >= 0) {
    final whole = shortest.length > exponent + 1
        ? '${shortest.substring(0, exponent + 1)}.${shortest.substring(exponent + 1)}'
        : '${shortest.padRight(exponent + 1, '0')}.0';
    return '$sign$whole';
  }
  return '${sign}0.${'0' * (-exponent - 1)}$shortest';
}

/// json.dumps(value, indent=…, ensure_ascii=…): Python's separators, escapes
/// and number forms (", "/": " flat; "," and ": " with an indent).
String pyJsonDumps(dynamic value, {int? indent, bool ensureAscii = true}) {
  final out = StringBuffer();
  void string(String v) {
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
          if (unit < 0x20 || ensureAscii && unit > 0x7e) {
            out.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    out.write('"');
  }

  void write(dynamic v, int level) {
    final pad = indent == null ? '' : '\n${' ' * (indent * (level + 1))}';
    final close = indent == null ? '' : '\n${' ' * (indent * level)}';
    final comma = indent == null ? ', ' : ',';
    if (v is String) {
      string(v);
    } else if (v is bool) {
      out.write(v ? 'true' : 'false');
    } else if (v is int) {
      out.write('$v');
    } else if (v is double) {
      out.write(pyFloat(v));
    } else if (v is List) {
      if (v.isEmpty) {
        out.write('[]');
        return;
      }
      out.write('[');
      for (var i = 0; i < v.length; i++) {
        out.write(i == 0 ? pad : '$comma$pad');
        write(v[i], level + 1);
      }
      out.write('$close]');
    } else if (v is Map) {
      if (v.isEmpty) {
        out.write('{}');
        return;
      }
      out.write('{');
      var first = true;
      for (final e in v.entries) {
        out.write(first ? pad : '$comma$pad');
        first = false;
        string('${e.key}');
        out.write(': ');
        write(e.value, level + 1);
      }
      out.write('$close}');
    } else {
      out.write('null');
    }
  }

  write(value, 0);
  return out.toString();
}

/// Python's repr() of a JSON value (str() of a list or dict uses it).
String pyRepr(dynamic v) => switch (v) {
  String s => _reprStr(s),
  List l => '[${l.map(pyRepr).join(', ')}]',
  Map m =>
    '{${m.entries.map((e) => '${pyRepr(e.key)}: ${pyRepr(e.value)}').join(', ')}}',
  double d => pyFloat(d),
  _ => pyStr(v),
};

String _reprStr(String s) {
  final quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final r in s.runes) {
    if (r == 0x5c) {
      out.write(r'\\');
    } else if (r == quote.codeUnitAt(0)) {
      out.write('\\$quote');
    } else if (r == 10) {
      out.write(r'\n');
    } else if (r == 13) {
      out.write(r'\r');
    } else if (r == 9) {
      out.write(r'\t');
    } else if (r < 0x20 || r == 0x7f) {
      out.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else if (r >= 0x80 && r < 0xa0) {
      out.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else {
      out.writeCharCode(r);
    }
  }
  out.write(quote);
  return out.toString();
}

/// Python's f"{x:.Nf}" exactly: the double's exact value rounded to N
/// places, a tie to the even digit (toStringAsFixed rounds ties away).
String pyFixedExact(double x, int places) {
  if (!x.isFinite) return x.toString();
  final bits = (ByteData(8)..setFloat64(0, x)).getUint64(0);
  final negative = bits >> 63 == 1;
  final exponent = (bits >> 52) & 0x7ff;
  final fraction = bits & 0xfffffffffffff;
  var mantissa = BigInt.from(exponent == 0 ? fraction : fraction | (1 << 52));
  var shift =
      (exponent == 0 ? 1 : exponent) - 1075; // value = mantissa * 2^shift
  var numerator = mantissa * BigInt.from(10).pow(places);
  var denominator = BigInt.one;
  if (shift >= 0) {
    numerator <<= shift;
  } else {
    denominator <<= -shift;
  }
  var q = numerator ~/ denominator;
  final twice = (numerator % denominator) * BigInt.two;
  if (twice > denominator || twice == denominator && q.isOdd) q += BigInt.one;
  var digits = q.toString().padLeft(places + 1, '0');
  final text = places == 0
      ? digits
      : '${digits.substring(0, digits.length - places)}.${digits.substring(digits.length - places)}';
  return negative && q != BigInt.zero ? '-$text' : text;
}
