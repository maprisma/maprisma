import 'package:yaml/yaml.dart';

/// PyYAML's yaml.dump(data, Dumper=SafeDumper, sort_keys=False,
/// default_flow_style=False, allow_unicode=True) for str, int, float, bool,
/// None, lists and maps: the emitter's block layout, scalar analysis, style
/// choice, YAML 1.1 implicit types and 80-column splitting.
String pyYamlDump(dynamic data) => _Emitter().document(data);

const _breaks = {0x0a, 0x85, 0x2028, 0x2029};
const _space = {0x00, 0x20, 0x09, 0x0d, 0x0a, 0x85, 0x2028, 0x2029};

bool _printableUnicode(int c) =>
    (c == 0x85 ||
        c >= 0xa0 && c <= 0xd7ff ||
        c >= 0xe000 && c <= 0xfffd ||
        c >= 0x10000 && c < 0x10ffff) &&
    c != 0xfeff;

/// yaml.resolver's implicit resolvers (the first one matching decides).
bool _resolvesToOtherType(String value) {
  if (value.isEmpty) return true; // null
  final first = value[0];
  bool match(String pattern) =>
      RegExp('^(?:$pattern)\$').hasMatch(value) ||
      value.endsWith('\n') &&
          RegExp(
            '^(?:$pattern)\$',
          ).hasMatch(value.substring(0, value.length - 1));
  if ('yYnNtTfFoO'.contains(first) &&
      match(
        'yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF',
      )) {
    return true;
  }
  if ('-+0123456789.'.contains(first) &&
      match(
        r'[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?'
        r'|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN)',
      )) {
    return true;
  }
  if ('-+0123456789'.contains(first) &&
      match(
        r'[-+]?0b[0-1_]+|[-+]?0[0-7_]+|[-+]?(?:0|[1-9][0-9_]*)|[-+]?0x[0-9a-fA-F_]+'
        r'|[-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+',
      )) {
    return true;
  }
  if (first == '<' && match('<<')) return true;
  if ('~nN'.contains(first) && match('~|null|Null|NULL')) return true;
  if ('0123456789'.contains(first) &&
      match(
        r'[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?'
        r'|[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?(?:[Tt]|[ \t]+)[0-9][0-9]?:[0-9][0-9]:[0-9][0-9]'
        r'(?:\.[0-9]*)?(?:[ \t]*(?:Z|[-+][0-9][0-9]?(?::[0-9][0-9])?))?',
      )) {
    return true;
  }
  if (first == '=' && match('=')) return true;
  return false;
}

final class _Analysis {
  bool empty = false, multiline = false;
  bool flowPlain = true, blockPlain = true, singleQuoted = true;
}

_Analysis _analyze(List<int> s) {
  final a = _Analysis();
  if (s.isEmpty) {
    a
      ..empty = true
      ..flowPlain = false;
    return a;
  }
  var blockIndicators = false,
      flowIndicators = false,
      lineBreaks = false,
      special = false;
  var leadingSpace = false,
      leadingBreak = false,
      trailingSpace = false,
      trailingBreak = false;
  var breakSpace = false, spaceBreak = false;
  var preceded = true, followed = s.length == 1 || _space.contains(s[1]);
  var previousSpace = false, previousBreak = false;
  final text = String.fromCharCodes(s);
  if (text.startsWith('---') || text.startsWith('...')) {
    blockIndicators = flowIndicators = true;
  }
  for (var i = 0; i < s.length; i++) {
    final c = s[i], ch = String.fromCharCode(c);
    if (i == 0) {
      if ('#,[]{}&*!|>\'"%@`'.contains(ch)) {
        flowIndicators = blockIndicators = true;
      }
      if ('?:'.contains(ch)) {
        flowIndicators = true;
        if (followed) blockIndicators = true;
      }
      if (ch == '-' && followed) flowIndicators = blockIndicators = true;
    } else {
      if (',?[]{}'.contains(ch)) flowIndicators = true;
      if (ch == ':') {
        flowIndicators = true;
        if (followed) blockIndicators = true;
      }
      if (ch == '#' && preceded) flowIndicators = blockIndicators = true;
    }
    if (_breaks.contains(c)) lineBreaks = true;
    if (!(c == 0x0a || c >= 0x20 && c <= 0x7e)) {
      if (!_printableUnicode(c)) special = true;
    }
    if (c == 0x20) {
      if (i == 0) leadingSpace = true;
      if (i == s.length - 1) trailingSpace = true;
      if (previousBreak) breakSpace = true;
      previousSpace = true;
      previousBreak = false;
    } else if (_breaks.contains(c)) {
      if (i == 0) leadingBreak = true;
      if (i == s.length - 1) trailingBreak = true;
      if (previousSpace) spaceBreak = true;
      previousSpace = false;
      previousBreak = true;
    } else {
      previousSpace = previousBreak = false;
    }
    preceded = _space.contains(c);
    followed = i + 2 >= s.length || _space.contains(s[i + 2]);
  }
  if (leadingSpace || leadingBreak || trailingSpace || trailingBreak) {
    a.flowPlain = a.blockPlain = false;
  }
  if (breakSpace) a.flowPlain = a.blockPlain = a.singleQuoted = false;
  if (spaceBreak || special) {
    a.flowPlain = a.blockPlain = a.singleQuoted = false;
  }
  if (lineBreaks) a.flowPlain = a.blockPlain = false;
  if (flowIndicators) a.flowPlain = false;
  if (blockIndicators) a.blockPlain = false;
  a.multiline = lineBreaks;
  return a;
}

const _escapes = {
  0x00: '0',
  0x07: 'a',
  0x08: 'b',
  0x09: 't',
  0x0a: 'n',
  0x0b: 'v',
  0x0c: 'f',
  0x0d: 'r', //
  0x1b: 'e',
  0x22: '"',
  0x5c: '\\',
  0x85: 'N',
  0xa0: '_',
  0x2028: 'L',
  0x2029: 'P',
};

final class _Emitter {
  final out = StringBuffer();
  int column = 0;
  bool whitespace = true, indention = true;
  int? indent;
  final indents = <int?>[];
  static const width = 80;

  void _write(String s) {
    out.write(s);
    column += s.runes.length;
  }

  void lineBreak() {
    whitespace = indention = true;
    column = 0;
    out.write('\n');
  }

  void writeIndent() {
    final want = indent ?? 0;
    if (!indention || column > want || column == want && !whitespace) {
      lineBreak();
    }
    if (column < want) {
      whitespace = true;
      out.write(' ' * (want - column));
      column = want;
    }
  }

  void indicator(
    String text,
    bool needWhitespace, {
    bool white = false,
    bool indent = false,
  }) {
    _write(whitespace || !needWhitespace ? text : ' $text');
    whitespace = white;
    indention = indention && indent;
  }

  void increase({bool flow = false, bool indentless = false}) {
    indents.add(indent);
    if (indent == null) {
      indent = flow ? 2 : 0;
    } else if (!indentless) {
      indent = indent! + 2;
    }
  }

  void decrease() => indent = indents.removeLast();

  String document(dynamic data) {
    node(data, root: true);
    lineBreak();
    return out.toString();
  }

  void node(
    dynamic v, {
    bool root = false,
    bool mapping = false,
    bool simpleKey = false,
  }) {
    if (v is Map) {
      if (v.isEmpty) {
        indicator('{', true, white: true);
        indicator('}', false);
        return;
      }
      increase();
      for (final e in v.entries) {
        writeIndent();
        node(e.key, mapping: true, simpleKey: true);
        indicator(':', false);
        node(e.value, mapping: true);
      }
      decrease();
    } else if (v is List) {
      if (v.isEmpty) {
        indicator('[', true, white: true);
        indicator(']', false);
        return;
      }
      increase(indentless: mapping && !indention);
      for (final item in v) {
        writeIndent();
        indicator('-', true, indent: true);
        node(item);
      }
      decrease();
    } else {
      scalar(v, simpleKey: simpleKey);
    }
  }

  void scalar(dynamic v, {bool simpleKey = false}) {
    increase(flow: true);
    if (v == null) {
      plain('null', split: !simpleKey);
    } else if (v is bool) {
      plain(v ? 'true' : 'false', split: !simpleKey);
    } else if (v is int) {
      plain('$v', split: !simpleKey);
    } else if (v is double) {
      plain(_float(v), split: !simpleKey);
    } else {
      final text = '$v', runes = text.runes.toList(), a = _analyze(runes);
      final implicit = !_resolvesToOtherType(text);
      if (implicit &&
          !(simpleKey && (a.empty || a.multiline)) &&
          a.blockPlain) {
        plain(text, split: !simpleKey);
      } else if (a.singleQuoted && !(simpleKey && a.multiline)) {
        singleQuoted(runes, split: !simpleKey);
      } else {
        doubleQuoted(runes, split: !simpleKey);
      }
    }
    decrease();
  }

  static String _float(double d) {
    if (d.isNaN) return '.nan';
    if (d.isInfinite) return d > 0 ? '.inf' : '-.inf';
    var value = _repr(d).toLowerCase();
    if (!value.contains('.') && value.contains('e')) {
      value = value.replaceFirst('e', '.0e');
    }
    return value;
  }

  static String _repr(double d) {
    // Python repr: shortest digits; exponent below 1e-4 and from 1e16.
    final text = d.abs().toStringAsExponential();
    final digits = text
        .split('e')[0]
        .replaceAll('.', '')
        .replaceFirst(RegExp(r'0+$'), '');
    final e = int.parse(text.split('e')[1]);
    final m = digits.isEmpty ? '0' : digits, sign = d < 0 ? '-' : '';
    if (d == 0) return d.isNegative ? '-0.0' : '0.0';
    if (e < -4 || e >= 16) {
      return '$sign${m.length > 1 ? '${m[0]}.${m.substring(1)}' : m}e${e < 0 ? '-' : '+'}${e.abs().toString().padLeft(2, '0')}';
    }
    if (e >= 0) {
      return m.length > e + 1
          ? '$sign${m.substring(0, e + 1)}.${m.substring(e + 1)}'
          : '$sign${m.padRight(e + 1, '0')}.0';
    }
    return '${sign}0.${'0' * (-e - 1)}$m';
  }

  void plain(String text, {bool split = true}) {
    if (text.isEmpty) return;
    if (!whitespace) _write(' ');
    whitespace = indention = false;
    final s = text.runes.toList();
    var spaces = false, start = 0;
    for (var end = 0; end <= s.length; end++) {
      final c = end < s.length ? s[end] : null;
      if (spaces) {
        if (c != 0x20) {
          if (start + 1 == end && column > width && split) {
            writeIndent();
            whitespace = indention = false;
          } else {
            _write(String.fromCharCodes(s.sublist(start, end)));
          }
          start = end;
        }
      } else if (c == null || c == 0x20 || _breaks.contains(c)) {
        _write(String.fromCharCodes(s.sublist(start, end)));
        start = end;
      }
      if (c != null) spaces = c == 0x20;
    }
  }

  void singleQuoted(List<int> s, {bool split = true}) {
    indicator("'", true);
    var spaces = false, breaks = false, start = 0;
    for (var end = 0; end <= s.length; end++) {
      final c = end < s.length ? s[end] : null;
      if (spaces) {
        if (c == null || c != 0x20) {
          if (start + 1 == end &&
              column > width &&
              split &&
              start != 0 &&
              end != s.length) {
            writeIndent();
          } else {
            _write(String.fromCharCodes(s.sublist(start, end)));
          }
          start = end;
        }
      } else if (breaks) {
        if (c == null || !_breaks.contains(c)) {
          if (s[start] == 0x0a) lineBreak();
          for (final br in s.sublist(start, end)) {
            if (br == 0x0a) {
              lineBreak();
            } else {
              out.writeCharCode(br);
              whitespace = indention = true;
              column = 0;
            }
          }
          writeIndent();
          start = end;
        }
      } else if (c == null || c == 0x20 || _breaks.contains(c) || c == 0x27) {
        if (start < end) {
          _write(String.fromCharCodes(s.sublist(start, end)));
          start = end;
        }
      }
      if (c == 0x27) {
        _write("''");
        start = end + 1;
      }
      if (c != null) {
        spaces = c == 0x20;
        breaks = _breaks.contains(c);
      }
    }
    indicator("'", false);
  }

  void doubleQuoted(List<int> s, {bool split = true}) {
    indicator('"', true);
    var start = 0;
    for (var end = 0; end <= s.length; end++) {
      final c = end < s.length ? s[end] : null;
      if (c == null ||
          const {0x22, 0x5c, 0x85, 0x2028, 0x2029, 0xfeff}.contains(c) ||
          !(c >= 0x20 && c <= 0x7e ||
              (c >= 0xa0 && c <= 0xd7ff || c >= 0xe000 && c <= 0xfffd))) {
        if (start < end) {
          _write(String.fromCharCodes(s.sublist(start, end)));
          start = end;
        }
        if (c != null) {
          final String data;
          if (_escapes.containsKey(c)) {
            data = '\\${_escapes[c]}';
          } else if (c <= 0xff) {
            data = '\\x${c.toRadixString(16).toUpperCase().padLeft(2, '0')}';
          } else if (c <= 0xffff) {
            data = '\\u${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';
          } else {
            data = '\\U${c.toRadixString(16).toUpperCase().padLeft(8, '0')}';
          }
          _write(data);
          start = end + 1;
        }
      }
      if (end > 0 &&
          end < s.length - 1 &&
          (c == 0x20 || start >= end) &&
          column + (end - start) > width &&
          split) {
        _write('${String.fromCharCodes(s.sublist(start, end))}\\');
        if (start < end) start = end;
        writeIndent();
        whitespace = indention = false;
        if (s[start] == 0x20) _write('\\');
      }
    }
    indicator('"', false);
  }
}

/// What PyYAML's SafeLoader constructs, for documents this app writes back:
/// plain scalars resolved by YAML 1.1 (yes/on booleans, 0x/0o/sexagesimal
/// ints, floats only with a dot, ~ and empty as null). Values PyYAML would
/// write back differently from their source and this dumper cannot write
/// (dates, explicit tags such as !!js, anchors and aliases, merge keys) refuse.
dynamic pyYamlLoad(String text) {
  if (RegExp(r'(^|[\s\[{,:-])[&*][^\s]').hasMatch(text)) {
    throw UnsupportedError('anchors and aliases');
  }
  if (RegExp(r'(^|[\s\[{,:-])!').hasMatch(text)) {
    throw UnsupportedError('explicit tags');
  }
  return _construct(loadYamlNode(text));
}

dynamic _construct(YamlNode node) {
  if (node is YamlMap) {
    final out = <dynamic, dynamic>{};
    for (final e in node.nodes.entries) {
      final key = _construct(e.key as YamlNode);
      if (key == '<<' && (e.key as YamlScalar).style == ScalarStyle.PLAIN) {
        throw UnsupportedError('merge keys');
      }
      out[key] = _construct(e.value);
    }
    return out;
  }
  if (node is YamlList) return [for (final n in node.nodes) _construct(n)];
  final scalar = node as YamlScalar;
  if (scalar.style != ScalarStyle.PLAIN) return '${scalar.value ?? ''}';
  return _resolvePlain(scalar.span.text, scalar.value);
}

dynamic _resolvePlain(String raw, dynamic parsed) {
  final text = raw.trim();
  if (text.isEmpty || const {'~', 'null', 'Null', 'NULL'}.contains(text)) {
    return null;
  }
  if (const {
    'yes',
    'Yes',
    'YES',
    'true',
    'True',
    'TRUE',
    'on',
    'On',
    'ON',
  }.contains(text)) {
    return true;
  }
  if (const {
    'no',
    'No',
    'NO',
    'false',
    'False',
    'FALSE',
    'off',
    'Off',
    'OFF',
  }.contains(text)) {
    return false;
  }
  if (RegExp(
    r'^[-+]?(?:0b[0-1_]+|0[0-7_]+|(?:0|[1-9][0-9_]*)|0x[0-9a-fA-F_]+|[1-9][0-9_]*(?::[0-5]?[0-9])+)$',
  ).hasMatch(text)) {
    return _int(text);
  }
  if (RegExp(
    r'^(?:[-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?'
    r'|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$',
  ).hasMatch(text)) {
    return _float(text);
  }
  if (RegExp(r'^[0-9][0-9][0-9][0-9]-[0-9][0-9]?-[0-9][0-9]?').hasMatch(text) &&
      _resolvesToOtherType(text)) {
    throw UnsupportedError('dates');
  }
  if (text == '=' || text == '<<') {
    throw UnsupportedError('value and merge keys');
  }
  // A plain string: package:yaml folds multi-line plain scalars as YAML does.
  return parsed is String ? parsed : text;
}

int _int(String text) {
  var value = text.replaceAll('_', '');
  var sign = 1;
  if (value.startsWith('-')) sign = -1;
  if ('+-'.contains(value[0])) value = value.substring(1);
  if (value == '0') return 0;
  if (value.startsWith('0b')) {
    return sign * int.parse(value.substring(2), radix: 2);
  }
  if (value.startsWith('0x')) {
    return sign * int.parse(value.substring(2), radix: 16);
  }
  if (value.startsWith('0')) return sign * int.parse(value, radix: 8);
  if (value.contains(':')) {
    var total = 0;
    for (final part in value.split(':')) {
      total = total * 60 + int.parse(part);
    }
    return sign * total;
  }
  return sign * int.parse(value);
}

double _float(String text) {
  var value = text.replaceAll('_', '').toLowerCase();
  var sign = 1.0;
  if (value.startsWith('-')) sign = -1.0;
  if ('+-'.contains(value[0])) value = value.substring(1);
  if (value == '.inf') return sign * double.infinity;
  if (value == '.nan') return double.nan;
  if (value.contains(':')) {
    var total = 0.0;
    for (final part in value.split(':')) {
      total = total * 60 + double.parse(part);
    }
    return sign * total;
  }
  return sign * double.parse(value);
}
