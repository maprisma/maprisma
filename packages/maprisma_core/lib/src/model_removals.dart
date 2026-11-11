import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'connect_apply.dart' show ConfigFiles;
import 'context.dart' show ContextReader;
import 'installers.dart' show InstallHost, KoboldCppInstaller;
import 'model_downloads.dart' show ModelFiles, realpathLoose;
import 'model_hub.dart' show ModelHub, boundedOutput;
import 'provider_ops.dart';
import 'provider_scans.dart';
import 'scan_files.dart';

const maxRemovalBytes = 1024 * 1024;
final _split = RegExp(r'^(.*)-(\d{5})-of-(\d{5})\.gguf$');

/// models_ctl.Removal: what goes to the trash.
typedef Removal = ({
  List<String> paths,
  int size,
  bool linksOnly,
  List<String> shared,
});

/// flutter_removals: removing a local LLM's model, previewed and checked
/// again in the worker before anything goes.
final class ModelRemovals {
  ModelRemovals(this.files) : ops = ProviderOps(files, ProviderScans(files));
  final ScanFiles files;
  final ProviderOps ops;

  Map get _engines => providerFacts['engines'] as Map;
  String _engine(String key, String fact) =>
      '${(_engines[key] as Map?)?[fact] ?? ''}';
  String _expand(String path) => files.expand(path);
  bool _isLink(String path) => FileSystemEntity.isLinkSync(path);

  /// flutter_removals._identity: path, where it leads, and its lstat.
  List<dynamic> identity(String path) {
    final st = files.posix.lstatFull(path);
    if (st == null) throw FileSystemException('cannot be read', path);
    final sig = st.signature; // dev, ino, size, mtime_ns, ctime_ns
    return [
      path,
      realpathLoose(path),
      sig[0],
      sig[1],
      st.mode,
      sig[2],
      sig[3],
      _isLink(path) ? Link(path).targetSync() : null,
    ];
  }

  /// models_ctl._own_entry: a file or link of this account inside the folder.
  bool _ownEntry(String path, String inside) {
    final st = files.posix.lstatOwn(path);
    if (st == null) return false;
    final rel = p.relative(
      p.normalize(p.absolute(path)),
      from: p.normalize(p.absolute(inside)),
    );
    if (rel == '..' || rel.startsWith('../') || p.isAbsolute(rel)) return false;
    final type = st.mode & 0xf000;
    return st.uid == files.posix.uid &&
        (type == 0xa000 || FileSystemEntity.isFileSync(path)) &&
        !p.split(rel).contains('..');
  }

  /// Path.glob for one level: names matching (hidden ones too, as pathlib).
  List<String> _glob(String folder, RegExp name) {
    try {
      return [
        for (final e in Directory(folder).listSync(followLinks: false))
          if (name.hasMatch(p.basename(e.path))) e.path,
      ]..sort();
    } on FileSystemException {
      return [];
    }
  }

  /// `<literal>-*-of-<rest>.gguf` as a pattern (the literal part escaped).
  static RegExp _parts(String literal, String rest) => RegExp(
    '^${RegExp.escape(literal)}-.*-of-${rest == '*' ? '.*' : RegExp.escape(rest)}\\.gguf\$',
  );

  /// models_ctl.links_into: a .gguf link up to four levels down leading to one of targets.
  bool linksInto(String folder, Set<String> targets) {
    var count = 0;
    var level = [folder];
    for (var depth = 0; depth < 4; depth++) {
      final next = <String>[];
      for (final dir in level) {
        for (final path in _glob(dir, RegExp(r'\.gguf$'))) {
          if (++count > 5001) return false;
          if (_isLink(path) && targets.contains(realpathLoose(path))) {
            return true;
          }
        }
        next.addAll(
          _glob(dir, RegExp('.')).where(FileSystemEntity.isDirectorySync),
        );
      }
      level = next;
    }
    return false;
  }

  /// models_ctl.removal.
  Removal removal(
    String key,
    String modelsDir,
    String name,
    Map<String, (String, String)> others,
  ) {
    final dir = _expand(modelsDir);
    final kind = _engine(key, 'layout');
    List<String> paths;
    if (kind == 'publisher') {
      final context = ContextReader(
        files,
        ConfigFiles(files.posix, files.identity.home),
      );
      final file = context.lmstudioModelFile(context.lmstudioEntry(name));
      if (file == null) {
        throw const FormatException(
          'LM Studio does not list this model in its folder',
        );
      }
      final folder = p.dirname(file);
      final split = _split.firstMatch(p.basename(file));
      paths = split != null
          ? _glob(folder, _parts(split.group(1)!, split.group(3)!))
          : [file];
      final ggufs = _glob(folder, RegExp(r'\.gguf$'));
      final rest = ggufs.where(
        (x) =>
            !paths.contains(x) &&
            !p.basename(x).toLowerCase().contains('mmproj'),
      );
      if (rest.isEmpty) {
        paths = [
          ...paths,
          ...ggufs.where((x) => p.basename(x).toLowerCase().contains('mmproj')),
        ];
      }
    } else if (kind == 'flat') {
      final exact = '$dir/$name.gguf';
      if (FileSystemEntity.typeSync(exact, followLinks: false) !=
          FileSystemEntityType.notFound) {
        paths = [exact];
      } else {
        paths = _glob(
          dir,
          _parts(name, '*'),
        ).where((x) => _split.hasMatch(p.basename(x))).toList();
      }
    } else {
      throw const FormatException('this local LLM removes models itself');
    }
    if (paths.isEmpty || !paths.every((x) => _ownEntry(x, dir))) {
      throw const FormatException(
        "the model's files are not this account's own files in its model folder",
      );
    }
    final linksOnly = paths.every(_isLink);
    final size = linksOnly
        ? 0
        : paths
              .where((x) => !_isLink(x))
              .fold(0, (s, x) => s + File(x).lengthSync());
    final shared = <String>[];
    if (!linksOnly) {
      final gone = {
        for (final x in paths)
          if (!_isLink(x)) realpathLoose(x),
      };
      for (final MapEntry(key: other, value: (_, folder)) in others.entries) {
        if (folder.isNotEmpty && linksInto(_expand(folder), gone)) {
          shared.add(other);
        }
      }
    }
    return (paths: paths, size: size, linksOnly: linksOnly, shared: shared);
  }

  /// flutter_removals._record.
  (Map<String, dynamic>, RuntimeRecord) recordOf(String key, String model) {
    final rt = ops.runtime(key);
    if (!rt.installed ||
        model.isEmpty ||
        model.length > 300 ||
        !rt.models.contains(model)) {
      throw const FormatException('Model unavailable');
    }
    final mode = _engine(key, 'removable');
    if (mode != 'file' && mode != 'api') {
      throw const FormatException('This provider cannot remove models here');
    }
    List<dynamic>? root;
    if (rt.modelsDir.isNotEmpty) {
      final directory = _expand(rt.modelsDir);
      if (FileSystemEntity.isDirectorySync(directory)) {
        final real = Directory(directory).resolveSymbolicLinksSync();
        final st = files.posix.lstatOwn(real)!;
        root = [real, st.identity[0], st.identity[1]];
      }
    }
    final result = <String, dynamic>{
      'version': 1,
      'key': key,
      'provider_name': rt.name,
      'model': model,
      'mode': mode,
      'address': rt.address,
      'models_dir': rt.modelsDir,
      'root': root,
      'files': [],
      'size': 0,
      'links_only': false,
      'shared': [],
    };
    if (mode == 'file') {
      if (root == null) throw const FormatException('Model folder unavailable');
      final others = <String, (String, String)>{};
      for (final other in ops.providers.scan()) {
        if (other.key != key && other.modelsDir.isNotEmpty) {
          others[other.name] = (other.key, other.modelsDir);
        }
      }
      final found = removal(key, rt.modelsDir, model, others);
      result
        ..['files'] = [
          for (final x in [...found.paths]..sort()) identity(x),
        ]
        ..['size'] = found.size
        ..['links_only'] = found.linksOnly
        ..['shared'] = (List<String>.of(found.shared)..sort());
    }
    return (result, rt);
  }

  /// flutter_removals.execute: the same record again, then trash or delete.
  Future<Map<String, dynamic>> execute(Map snapshot) async {
    if (snapshot['version'] != 1) {
      throw const FormatException('Invalid private removal');
    }
    final (current, rt) = recordOf(
      snapshot['key'] as String,
      snapshot['model'] as String,
    );
    if (jsonEncode(current) != jsonEncode(snapshot)) {
      throw const FormatException(
        'The model or its shared references changed; preview again',
      );
    }
    if (snapshot['mode'] == 'file') {
      for (final entry in snapshot['files'] as List) {
        await trash((entry as List)[0] as String);
      }
    } else {
      await ollamaDelete(snapshot['model'] as String, rt.address);
    }
    if (rt.key == 'koboldcpp') {
      // KoboldCpp's engine.refresh: its .kcpps follow the model files.
      final kobold = KoboldCppInstaller(
        InstallHost(files.identity.home, files.posix),
      );
      final folder = kobold.modelsFolder();
      if (kobold.installedFolder() != null && folder.isNotEmpty) {
        await kobold.sync(folder);
      }
    }
    return {'ok': true, 'recoverable': snapshot['mode'] == 'file'};
  }

  /// models_ctl.trash: the desktop's trash (freedesktop.org), as GIO does it.
  Future<void> trash(String path) async {
    final (out, ok) = await boundedOutput(
      ['gio', 'trash', '--', path],
      timeout: const Duration(seconds: 60),
      mergeStderr: true,
    );
    if (!ok) {
      final text = utf8.decode(out, allowMalformed: true).trim();
      throw StateError(
        '${p.basename(path)} could not be moved to the trash: $text',
      );
    }
  }

  /// models_ctl.ollama_delete: Ollama removes one of its models.
  Future<void> ollamaDelete(String name, String address) async {
    if (!ModelHub.ollamaNameRe.hasMatch(name)) {
      throw const FormatException('not an Ollama model name');
    }
    final tail = address.split(':').last;
    final port = int.tryParse(tail.isEmpty ? '11434' : tail) ?? 11434;
    ModelFiles.requireOwnListener(port, files.posix.uid);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      // One deadline for the whole exchange (a trickling reply never holds it).
      final status = await withHttpDeadline<int>(
        client,
        const Duration(seconds: 60),
        () async {
          final request = await client.openUrl(
            'DELETE',
            Uri.parse('http://127.0.0.1:$port/api/delete'),
          );
          final body = utf8.encode(jsonEncode({'model': name}));
          request
            ..persistentConnection = false
            ..headers.contentType = ContentType.json
            ..contentLength = body.length
            ..add(body);
          final response = await request.close();
          var read = 0;
          await for (final chunk in response) {
            read += chunk.length;
            if (read > 1024 * 1024) break;
          }
          return response.statusCode;
        },
      );
      if (status == null) {
        throw StateError('Ollama: no answer in time');
      }
      if (status < 200 || status >= 300) {
        throw StateError('Ollama: the server answered $status');
      }
    } finally {
      client.close(force: true);
    }
  }
}

/// flutter_removals.Removals: opaque previews, used once within five minutes.
final class RemovalPreviews {
  RemovalPreviews(this.newToken);
  final String Function() newToken;
  final items = <String, (DateTime, Map<String, dynamic>)>{};

  Map<String, dynamic> preview(
    Map<String, dynamic> params,
    ModelRemovals removals,
  ) {
    if (params.length != 2 ||
        params['key'] is! String ||
        params['model'] is! String) {
      throw const FormatException('Invalid model removal');
    }
    final (snapshot, _) = removals.recordOf(
      params['key'] as String,
      params['model'] as String,
    );
    if (utf8.encode(jsonEncode(snapshot)).length > maxRemovalBytes) {
      throw const FormatException('Removal preview too large');
    }
    final now = DateTime.now();
    items.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 300);
    while (items.length >= 8) {
      items.remove(items.keys.first);
    }
    final token = newToken();
    items[token] = (now, snapshot);
    return {
      'removal': token,
      'model': snapshot['model'],
      'provider': snapshot['provider_name'],
      'address': snapshot['address'],
      'mode': snapshot['mode'],
      'files': [for (final e in snapshot['files'] as List) (e as List)[0]],
      'size': snapshot['size'],
      'links_only': snapshot['links_only'],
      'shared': snapshot['shared'],
    };
  }

  Map<String, dynamic> apply(
    String token,
    Map<String, dynamic> Function(Map<String, dynamic>) queue,
  ) {
    final kept = items[token];
    if (kept == null) throw const FormatException('Unknown removal preview');
    if (DateTime.now().difference(kept.$1).inSeconds >= 300) {
      throw const FormatException('Removal preview expired');
    }
    final result = queue(kept.$2);
    items.remove(token);
    return result;
  }
}
