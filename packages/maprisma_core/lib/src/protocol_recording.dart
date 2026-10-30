/// The protocol recording (MAPRISMA_RECORD_PROTOCOL): what a recorded line may
/// hold. A recording is read by people and agents later, so secrets are blanked
/// before it is written: values of secret-named fields, every value of an
/// `env` or `headers` map (an MCP server's keys live there; the names stay),
/// the key of an API-key route, and strings that look like a key wherever they
/// are.
library;

const recordBlank = '***';

final _secretName = RegExp(
  r'(^|_)(api_?key|apikey|token|access_token|refresh_token|id_token|password|'
  r'passphrase|secret|client_secret|authorization|cookie|credentials?|'
  r'private_key)$',
  caseSensitive: false,
);

final _secretText = RegExp(
  r'(sk-[A-Za-z0-9_-]{12,}|sk-ant-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{20,}|'
  r'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|'
  r'xox[abprs]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{16,}|'
  r'hf_[A-Za-z0-9]{20,}|Bearer\s+\S+)',
);

/// The routes whose `key` parameter is an API key, not a name.
const _keyRoutes = {'agents.key_preview', 'agents.key_apply'};

/// [value] as it may be recorded for [method].
Object? redactForRecord(String method, Object? value) =>
    _redact(value, keyIsSecret: _keyRoutes.contains(method));

Object? _redact(Object? value, {bool keyIsSecret = false, bool all = false}) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        e.key: _blank('${e.key}', keyIsSecret: keyIsSecret, all: all)
            ? _secret(e.value)
            : _redact(
                e.value,
                keyIsSecret: keyIsSecret,
                all: '${e.key}' == 'env' || '${e.key}' == 'headers',
              ),
    };
  }
  if (value is List) {
    return [
      for (final v in value) _redact(v, keyIsSecret: keyIsSecret, all: all),
    ];
  }
  if (value is String) return value.replaceAll(_secretText, recordBlank);
  return value;
}

/// A value under a secret name: text goes, everything inside a map or list
/// too; a number, true/false or null says nothing secret and stays.
Object? _secret(Object? value) => switch (value) {
  String() => recordBlank,
  Map() || List() => _redact(value, all: true),
  _ => value,
};

bool _blank(String name, {required bool keyIsSecret, required bool all}) =>
    all || _secretName.hasMatch(name) || (keyIsSecret && name == 'key');
