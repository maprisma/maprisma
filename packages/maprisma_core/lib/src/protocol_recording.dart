/// The protocol recording (MAPRISMA_RECORD_PROTOCOL): what a recorded line may
/// hold. A recording is read by people and agents later, so secrets are blanked
/// before it is written:
/// - everything under a secret name (`api_key`, `X-API-Key`, `OPENAI_KEY`,
///   `cookie` …): text, also inside lists and maps; numbers, true/false and
///   null stay (they say whether, not what);
/// - every value of an `env` or `headers` map and of the `values` an MCP
///   server form sends (the names stay; a list of names stays);
/// - in `args`: the value after a secret flag (`--token x`) and of a secret
///   `name=value` (`--api-key=x`, `API_KEY=x`);
/// - in every text: the password and query values of a URL, and strings that
///   look like a key (sk-…, AIza…, ghp_…, "Bearer …").
library;

const recordBlank = '***';

/// A field or flag name that holds a secret.
final _secretName = RegExp(
  r'((^|[_-])(api[_-]?key|apikey|token|access[_-]?token|refresh[_-]?token|'
  r'id[_-]?token|auth[_-]?token|password|passwd|passphrase|secret|'
  r'client[_-]?secret|authorization|cookie|credentials?|private[_-]?key)$)|'
  r'([_-]key$)',
  caseSensitive: false,
);

final _secretText = RegExp(
  r'(sk-[A-Za-z0-9_-]{12,}|sk-ant-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{20,}|'
  r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|'
  r'xox[abprs]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{16,}|'
  r'hf_[A-Za-z0-9]{20,}|Bearer\s+\S+)',
);

final _url = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s'"<>]+''');
final _flag = RegExp(r'^--?([A-Za-z0-9][A-Za-z0-9_-]*)$');
final _assignment = RegExp(
  r'^(--?)?([A-Za-z_][A-Za-z0-9_-]*)=(.*)$',
  dotAll: true,
);

/// Field names that end like a secret but are none (the core's own ids).
const _notSecret = {'fix_key'};

/// The routes whose `key` parameter is an API key, not a name.
const _keyRoutes = {'agents.key_preview', 'agents.key_apply'};

/// The routes whose `values` are what the user typed into an MCP server form.
const _formRoutes = {'mcp.option_test', 'mcp.option_preview'};

/// [value] as it may be recorded for [method].
Object? redactForRecord(String method, Object? value) =>
    _Redactor(method).plain(value);

final class _Redactor {
  _Redactor(this.method);
  final String method;

  bool _secretField(String name) =>
      (_secretName.hasMatch(name) && !_notSecret.contains(name)) ||
      (name == 'key' && _keyRoutes.contains(method));

  /// Outside any secret: names decide.
  Object? plain(Object? value) {
    if (value is Map) {
      return {
        for (final e in value.entries) e.key: _field('${e.key}', e.value),
      };
    }
    if (value is List) return [for (final v in value) plain(v)];
    if (value is String) return cleanText(value);
    return value;
  }

  Object? _field(String name, Object? value) {
    if (_secretField(name)) return secret(value);
    if ((name == 'env' || name == 'headers') && value is Map) {
      return valuesOf(value);
    }
    if (name == 'values' && value is Map && _formRoutes.contains(method)) {
      return valuesOf(value);
    }
    if (name == 'args' && value is List) return args(value);
    return plain(value);
  }

  /// Under a secret name: all text goes, numbers, true/false and null stay.
  Object? secret(Object? value) => switch (value) {
    String() => recordBlank,
    Map() => {for (final e in value.entries) e.key: secret(e.value)},
    List() => [for (final v in value) secret(v)],
    _ => value,
  };

  /// A map of names and values (env, headers, a form): the names stay.
  Map valuesOf(Map value) => {
    for (final e in value.entries) e.key: secret(e.value),
  };

  /// A program's arguments: what follows a secret flag, and the value of a
  /// secret name=value.
  List args(List value) {
    final out = [];
    var next = false;
    for (final v in value) {
      if (v is! String) {
        out.add(plain(v));
        next = false;
        continue;
      }
      if (next) {
        out.add(recordBlank);
        next = false;
        continue;
      }
      final assigned = _assignment.firstMatch(v);
      if (assigned != null && _secretName.hasMatch(assigned.group(2)!)) {
        out.add('${assigned.group(1) ?? ''}${assigned.group(2)}=$recordBlank');
        continue;
      }
      final flag = _flag.firstMatch(v);
      next = flag != null && _secretName.hasMatch(flag.group(1)!);
      out.add(cleanText(v));
    }
    return out;
  }
}

/// A text with key-like strings blanked and every URL's password and query
/// values blanked (`https://user:***@host/mcp?api_key=***`).
String cleanText(String text) => text
    .replaceAllMapped(_url, (m) => _cleanUrl(m[0]!))
    .replaceAll(_secretText, recordBlank);

String _cleanUrl(String text) {
  final url = Uri.tryParse(text);
  if (url == null || (url.userInfo.isEmpty && !url.hasQuery)) return text;
  final user = url.userInfo.isEmpty
      ? ''
      : url.userInfo.contains(':')
      ? '${url.userInfo.split(':').first}:$recordBlank'
      : recordBlank;
  final query = url.hasQuery
      ? url.query
            .split('&')
            .map(
              (p) => p.contains('=') ? '${p.split('=').first}=$recordBlank' : p,
            )
            .join('&')
      : null;
  return url
      .replace(userInfo: user.isEmpty ? null : user, query: query)
      .toString()
      .replaceAll('%2A%2A%2A', recordBlank);
}
