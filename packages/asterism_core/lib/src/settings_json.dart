import 'dart:convert';
import 'dart:math';

/// Preserve arbitrary-size legacy integers in unknown settings. dart:convert
/// otherwise silently rounds an out-of-range integer to double on the VM.
/// Strings are scanned without interpretation; JSON syntax remains the standard
/// decoder's responsibility. Markers cannot collide with any input string.
dynamic decodeSettings(String source) {
  // Validate first so replacing an invalid unquoted numeric object key cannot
  // accidentally turn malformed JSON into valid JSON.
  final original = jsonDecode(source);
  final strings = <String>{};
  void collect(dynamic value) {
    if (value is String) strings.add(value);
    if (value is List) value.forEach(collect);
    if (value is Map) {
      value.forEach((key, value) {
        collect(key);
        collect(value);
      });
    }
  }

  collect(original);
  final random = Random.secure();
  var marker = '';
  do {
    marker =
        '__asterism_integer_${random.nextInt(1 << 32)}_${random.nextInt(1 << 32)}__';
  } while (strings.any((value) => value.startsWith(marker)));
  final integers = <String, BigInt>{};
  final out = StringBuffer();
  var quoted = false, escaped = false;
  var offset = 0;
  final number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );
  while (offset < source.length) {
    final char = source[offset];
    if (quoted) {
      out.write(char);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      offset++;
      continue;
    }
    if (char == '"') {
      quoted = true;
      out.write(char);
      offset++;
      continue;
    }
    if (char == '-' || char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57) {
      final match = number.matchAsPrefix(source, offset);
      if (match != null) {
        final token = match.group(0)!;
        if (!token.contains(RegExp(r'[.eE]')) && int.tryParse(token) == null) {
          final key = '$marker${integers.length}';
          integers[key] = BigInt.parse(token);
          out.write(jsonEncode(key));
        } else {
          out.write(token);
        }
        offset = match.end;
        continue;
      }
    }
    out.write(char);
    offset++;
  }
  return jsonDecode(
    out.toString(),
    reviver: (key, value) => value is String && integers.containsKey(value)
        ? integers[value]
        : value,
  );
}
