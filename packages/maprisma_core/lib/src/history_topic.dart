import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

final _topicUrl = RegExp(
  r'''(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s<>"']+''',
);

String _redactSecrets(String text) {
  // A nested URL can be inside a decoded query value or fragment. Consume
  // the whole URL before looking for credentials to avoid repeated scans.
  text = text.replaceAllMapped(_topicUrl, (match) {
    final value = match[0]!;
    return value.contains('@') || value.toLowerCase().contains('%40')
        ? '…'
        : value;
  });
  // Provider prefixes are case-sensitive so ordinary words such as "Asian"
  // and hyphenated model names retain their meaning.
  text = text.replaceAll(
    RegExp(
      r'\b(?:sk-|gh[pousr]_|github_pat_|glpat-|AIza|AKIA|ASIA|xox[baprs]-|hf_|npm_|pypi-)[A-Za-z0-9_+=/.-]+',
    ),
    '…',
  );
  for (final pattern in [
    r'-----BEGIN [^-]{1,64}-----(?:.*?-----END [^-]{1,64}-----|.*$)',
    r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    r'\b(?:Bearer|Basic)\s+[^\s,;]+',
    r"""(?<![A-Za-z0-9_.-])(?:[A-Za-z_][A-Za-z0-9_.-]*)?(?:key|token|secret|password)["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)""",
    r'(?<![A-Za-z0-9+/_])(?:[A-Fa-f0-9]{32,}|[A-Za-z0-9+/]{30,}==|[A-Za-z0-9+/]{31,}=|[A-Za-z0-9+/]{32,})(?![A-Za-z0-9+/=_])',
    r'(?<![A-Za-z0-9.!#$%&*+/=?^_{}|~-])[A-Za-z0-9.!#$%&*+/=?^_{}|~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
  ]) {
    text = text.replaceAll(RegExp(pattern, caseSensitive: false), '…');
  }
  return text;
}

/// The entire request is sanitized before the 120-rune display bound.
String? sanitizeTopic(Object? value) {
  if (value is! String) return null;
  var text = value
      .replaceAll(
        RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
        ' ',
      )
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final urls = <String>[];
  text = text.replaceAllMapped(_topicUrl, (match) {
    try {
      final uri = Uri.tryParse(match[0]!);
      if (uri == null ||
          uri.userInfo.isNotEmpty ||
          _redactSecrets(uri.host) != uri.host) {
        return '…';
      }
      if (uri.queryParametersAll.keys.any(
        (key) => _redactSecrets(key) != key,
      )) {
        return '…';
      }
      final query = <String, dynamic>{
        for (final entry in uri.queryParametersAll.entries)
          entry.key:
              RegExp(
                r'(?:token|key|secret|auth|sig|password)$',
                caseSensitive: false,
              ).hasMatch(entry.key)
              ? '…'
              : entry.value.map(_redactSecrets).toList(),
      };
      urls.add(
        uri
            .replace(
              pathSegments: uri.pathSegments.map(_redactSecrets).toList(),
              queryParameters: query.isEmpty ? null : query,
              fragment: uri.hasFragment
                  ? _redactSecrets(Uri.decodeComponent(uri.fragment))
                  : null,
            )
            .toString(),
      );
      return '⟦url${urls.length - 1}⟧';
    } on FormatException {
      return '…';
    }
  });
  text = _redactSecrets(text);
  text = text.replaceAllMapped(
    RegExp(r"""(^|[\s("'=])((?:~/|/)[^\s<>"']+)"""),
    (match) => '${match[1]}${p.basename(match[2]!)}',
  );
  text = text.replaceAllMapped(RegExp(r'⟦url(\d+)⟧'), (match) {
    final index = int.tryParse(match[1]!);
    return index != null && index < urls.length ? urls[index] : '…';
  });
  text = String.fromCharCodes(text.trim().runes.take(120));
  return text.isEmpty ? null : text;
}

String historySession(String value) =>
    RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value)
    ? value
    : sha256.convert(utf8.encode(value)).toString();
