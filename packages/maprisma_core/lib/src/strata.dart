import 'dart:io';

import 'package:path/path.dart' as p;

import 'provider_scans.dart' show portNumber;
import 'scan_files.dart';

/// provider_strata: Strata's folders, its own `strata`, its run configs and
/// launch presets, as the reference reads them (read-only, bounded).
final class StrataFacts {
  StrataFacts(this.files);
  final ScanFiles files;

  static final modelId = RegExp(r'^[a-z0-9](?:[a-z0-9_-]|\.(?!\.)){0,127}$');
  static final presetName = RegExp(r'^[a-z][a-z0-9_-]{0,47}$');
  static const maxItems = 128, maxJson = 256 * 1024, defaultPort = 8080;
  static const startTimeout = Duration(seconds: 900);

  String _xdg(String name, String fallback) {
    final value = files.identity.environment[name] ?? '';
    return value.startsWith('/')
        ? value
        : p.join(files.identity.home, fallback);
  }

  String get dataDir => p.join(_xdg('XDG_DATA_HOME', '.local/share'), 'strata');
  String get installDir => p.join(dataDir, 'install');
  String get presetsDir =>
      p.join(_xdg('XDG_CONFIG_HOME', '.config'), 'strata', 'launch-presets');

  String? _resolve(String path) {
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }

  static bool _executableFile(String path) {
    try {
      final info = File(path).statSync();
      return info.type == FileSystemEntityType.file && info.mode & 0x49 != 0;
    } on FileSystemException {
      return false;
    }
  }

  String? _which(String name) {
    for (final folder in (files.identity.environment['PATH'] ?? '').split(
      ':',
    )) {
      if (folder.isEmpty) continue;
      final path = p.join(folder, name);
      if (_executableFile(path)) return path;
    }
    return null;
  }

  /// provider_strata.strata_binary: only a `strata` that resolves into its
  /// terminal folder (not the Strata file manager, /usr/bin/strata).
  String? binary() {
    final terminal = p.join(dataDir, 'terminal');
    final root = Directory(terminal).existsSync() ? _resolve(terminal) : null;
    if (root == null) return null;
    for (final candidate in [
      _which('strata'),
      p.join(files.identity.home, '.local/bin/strata'),
      p.join(terminal, 'current/bin/strata'),
    ]) {
      if (candidate == null) continue;
      final real = _resolve(candidate);
      if (real != null && p.isWithin(root, real) && _executableFile(real)) {
        return candidate;
      }
    }
    return null;
  }

  Map<String, dynamic> _json(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return {};
    }
    try {
      if (File(path).lengthSync() > maxJson) return {};
    } on FileSystemException {
      return {};
    }
    return files.json(path, limit: maxJson, comments: false);
  }

  static int _port(dynamic value) =>
      value is int && value > 0 && value < 65536 ? value : 0;

  /// provider_strata.model_ids: the ids of its `strata-<id>.json` run configs.
  List<String> modelIds() {
    final found = <String>[];
    final entries = files.list(installDir)..sort();
    for (final path in entries.take(4 * maxItems)) {
      final name = p.basename(path);
      if (!name.startsWith('strata-') ||
          !name.endsWith('.json') ||
          name.endsWith('.shared-settings.json')) {
        continue;
      }
      final value = name.substring(7, name.length - 5);
      if (modelId.hasMatch(value) &&
          FileSystemEntity.typeSync(path, followLinks: false) ==
              FileSystemEntityType.file) {
        found.add(value);
      }
    }
    return found.take(maxItems).toList();
  }

  /// provider_strata.last_preset: (slug, port) of the launch preset used
  /// last; only these fields are read (a preset may hold the API key).
  (String, int) lastPreset() {
    var best = ('', 0), bestTime = '';
    final paths =
        files
            .list(presetsDir)
            .where(
              (path) =>
                  path.endsWith('.json') && !p.basename(path).startsWith('.'),
            )
            .toList()
          ..sort();
    for (final path in paths.take(maxItems)) {
      final name = p.basename(path);
      final slug = name.substring(0, name.length - 5);
      if (!presetName.hasMatch(slug)) continue;
      final data = _json(path);
      if (data.isEmpty) continue;
      final raw = data['last_used'] is String && data['last_used'] != ''
          ? data['last_used']
          : data['created'];
      final stamp = raw is String && raw.length <= 40 ? raw : '';
      if (best.$1.isEmpty || stamp.compareTo(bestTime) > 0) {
        final port = _port(data['port']);
        best = (slug, port == 0 ? defaultPort : port);
        bestTime = stamp;
      }
    }
    return best;
  }

  /// provider_strata.is_server: `… -m serve.server` from its terminal.
  static bool isServer(List<String> argv) =>
      argv.isNotEmpty &&
      argv.first.contains('/strata/terminal/') &&
      argv.skip(1).take(3).contains('serve.server');

  /// provider_strata.server_port: the first --port N (1-5 ASCII digits,
  /// 1..65535; any other value is skipped), else its run config's port.
  int serverPort(List<String> argv) {
    for (var i = 0; i < argv.length; i++) {
      final value = argv[i] == '--port' && i + 1 < argv.length
          ? argv[i + 1]
          : argv[i].startsWith('--port=')
          ? argv[i].substring(7)
          : null;
      if (value != null && portNumber(value) != 0) return portNumber(value);
    }
    for (var i = 0; i + 1 < argv.length; i++) {
      if (argv[i] == '--config' && argv[i + 1].startsWith('/')) {
        final port = _port(_json(argv[i + 1])['port']);
        return port == 0 ? defaultPort : port;
      }
    }
    return defaultPort;
  }

  /// provider_strata.Engine.owns_process: its terminal's Python and its
  /// engine binary.
  static bool ownsPath(String exe) =>
      exe.contains('/strata/terminal/') || exe.contains('/strata/components/');
}
