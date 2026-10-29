import 'dart:async';
import 'package:crypto/crypto.dart' hide sha256;
import 'package:crypto/crypto.dart' as hashes show sha256;
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path/path.dart' as p;
import 'adapter_assets.g.dart';
import 'model_hub.dart';
import 'posix_ffi.dart';
import 'provider_ops.dart';
import 'py_values.dart';

typedef Progress = void Function(double fraction, String text);

/// llm_engine.layout: "flat", "publisher", "blobs" or "".
String modelLayout(String key) =>
    '${(providerFacts['engines'] as Map)[key]?['layout'] ?? ''}';

/// os.path.realpath without strict: links resolved as far as they lead.
String realpathLoose(String path) {
  var current = p.normalize(p.absolute(path));
  for (var i = 0; i < 40; i++) {
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) break;
    if (type != FileSystemEntityType.link) {
      return type == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinksSync()
          : File(current).resolveSymbolicLinksSync();
    }
    final target = Link(current).targetSync();
    current = p.normalize(
      p.isAbsolute(target) ? target : p.join(p.dirname(current), target),
    );
  }
  // What is missing stays as written below the parent that exists.
  final parent = p.dirname(current);
  if (parent == current) return current;
  return p.join(realpathLoose(parent), p.basename(current));
}

/// os.path.commonpath of absolute paths.
String commonPath(Iterable<String> paths) {
  List<String>? common;
  for (final path in paths) {
    final parts = p.split(p.normalize(path));
    if (common == null) {
      common = parts;
      continue;
    }
    var n = 0;
    while (n < common.length && n < parts.length && common[n] == parts[n]) {
      n++;
    }
    common = common.sublist(0, n);
  }
  return common == null || common.isEmpty ? '/' : p.joinAll(common);
}

final class ModelFiles {
  ModelFiles(this.posix, {ModelHub? hub}) : hub = hub ?? ModelHub();
  final Posix posix;
  final ModelHub hub;
  static const maxDownload = 8 * 1024 * 1024 * 1024;
  static final _split = RegExp(r'^(.*)-(\d{5})-of-(\d{5})\.gguf$');

  bool _isDir(int mode) => mode & 0xf000 == 0x4000;
  bool _isRegular(int mode) => mode & 0xf000 == 0x8000;

  /// models_ctl._private_folder: a real folder of this account nobody else
  /// can write to.
  bool privateFolder(String path) {
    final info = posix.lstatOwn(path);
    return info != null &&
        _isDir(info.mode) &&
        info.uid == posix.uid &&
        info.mode & 0x12 == 0;
  }

  /// install_ctl.own_regular_file: a regular file of this account with one name.
  bool ownRegularFile(String path) {
    final info = posix.lstatOwn(path);
    return info != null &&
        _isRegular(info.mode) &&
        info.uid == posix.uid &&
        info.nlink == 1;
  }

  bool _lexists(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  /// models_ctl.gguf_target: (folder to download into, folder to link from).
  (String, String?) ggufTarget(String key, String modelsDir, String repo) {
    if (modelLayout(key) == 'publisher') {
      final at = repo.indexOf('/');
      return (
        p.join(modelsDir, repo.substring(0, at), repo.substring(at + 1)),
        null,
      );
    }
    List<String> entries;
    try {
      entries = [
        for (final e in Directory(modelsDir).listSync(followLinks: false))
          if (p.basename(e.path).toLowerCase().endsWith('.gguf')) e.path,
      ];
    } on FileSystemException {
      entries = [];
    }
    if (entries.isNotEmpty &&
        entries.every(
          (e) =>
              FileSystemEntity.typeSync(e, followLinks: false) ==
              FileSystemEntityType.link,
        )) {
      final targets = {for (final e in entries) p.dirname(realpathLoose(e))};
      if (targets.length == 1) {
        final target = targets.first;
        return privateFolder(target) ? (target, modelsDir) : (modelsDir, null);
      }
      final common = commonPath(targets);
      final router = realpathLoose(modelsDir);
      if (p.split(common).length > 1 &&
          common != router &&
          !p.isWithin(router, common)) {
        final at = repo.indexOf('/');
        final publisher = repo.substring(0, at), name = repo.substring(at + 1);
        final chain = [
          common,
          p.join(common, publisher),
          p.join(common, publisher, name),
        ];
        if (chain.every(
          (c) => (c != common && !_lexists(c)) || privateFolder(c),
        )) {
          return (p.join(common, publisher, name), modelsDir);
        }
      }
    }
    return (modelsDir, null);
  }

  /// install_ctl.open_staging: created new (exclusive, no-follow) or, to
  /// resume, this account's own regular file with one name.
  int openStaging(String partial) {
    const flags = 0x2 | 0x400 | Posix.noFollow | Posix.cloexec;
    try {
      return posix.openAt(-100, partial, flags | 0x40 | 0x80, 0x1a4);
    } on FileSystemException {
      if (!_lexists(partial)) rethrow;
    }
    final int fd;
    try {
      fd = posix.openAt(-100, partial, flags);
    } on FileSystemException catch (error) {
      throw StateError(
        '${p.basename(partial)} is not a file this download can continue: ${error.message}',
      );
    }
    final st = posix.statFull(fd);
    if (!_isRegular(st.mode) || st.uid != posix.uid || st.nlink != 1) {
      posix.close(fd);
      throw StateError(
        "${p.basename(partial)} in ${p.dirname(partial)} is not this account's own download; "
        'remove it and try again',
      );
    }
    return fd;
  }

  /// install_ctl.download: curl into `<target>.part` (an open descriptor:
  /// curl never opens a path), resumed at our own file's size, capped by the
  /// announced size, renamed into place while the name still points at it.
  Future<void> download(
    String url,
    String target,
    int size,
    Progress progress, {
    int doneBefore = 0,
    int total = 0,
    String sha256 = '',
  }) async {
    Directory(p.dirname(target)).createSync(recursive: true);
    final partial = '$target.part';
    final limit = size != 0 ? size : maxDownload;
    final fd = openStaging(partial);
    try {
      var have = posix.statFull(fd).size;
      if (have > limit) {
        posix.truncate(fd, 0);
        have = 0;
      }
      final process = await Process.start('curl', [
        '-fsSL',
        '--proto',
        '=https',
        '--proto-redir',
        '=https',
        '--max-redirs',
        '5',
        '--max-filesize',
        '$limit',
        if (have > 0) ...['-C', '$have'],
        '--',
        url,
      ]);
      unawaited(process.stdin.close());
      final errors = <int>[];
      final errorsDone = process.stderr.forEach(
        (c) => errors.length < 400 ? errors.addAll(c) : null,
      );
      Object? failure;
      void report() {
        if (total != 0 || size != 0) {
          progress(
            (doneBefore + have) / math.max(1, total != 0 ? total : size),
            '',
          );
        } else {
          progress(
            have / (have + 200 * 1024 * 1024),
            '${have ~/ (1024 * 1024)} MB',
          );
        }
      }

      final ticker = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => report(),
      );
      try {
        await for (final chunk in process.stdout) {
          if (have + chunk.length > limit) {
            failure = StateError('the download is larger than announced');
            process.kill(ProcessSignal.sigkill);
            break;
          }
          posix.write(fd, chunk);
          have += chunk.length;
        }
      } finally {
        ticker.cancel();
      }
      final code = await process.exitCode;
      await errorsDone.catchError((_) {});
      if (failure != null) throw failure;
      if (code != 0) {
        final text = utf8.decode(
          errors.take(400).toList(),
          allowMalformed: true,
        );
        throw StateError('download failed: ${text.trim()}');
      }
      final st = posix.statFull(fd);
      if (size != 0 && st.size != size) {
        throw StateError('download incomplete');
      }
      if (sha256.isNotEmpty && digestOfFd(fd, sha256) != sha256) {
        posix.truncate(fd, 0);
        final now = posix.lstatOwn(partial);
        if (now != null && now.identity.join(':') == st.identity.join(':')) {
          File(partial).deleteSync();
        }
        throw StateError(
          "${p.basename(target)} does not match the release's checksum; nothing was installed",
        );
      }
      posix.sync(fd);
      final now = posix.lstatOwn(partial);
      if (now == null || now.identity.join(':') != st.identity.join(':')) {
        throw StateError(
          '${p.basename(partial)} was replaced while downloading; nothing was kept',
        );
      }
      File(partial).renameSync(target);
    } finally {
      posix.close(fd);
    }
  }

  /// install_ctl._sha256_of_fd: SHA-512 for 128 hex digits, else SHA-256.
  String digestOfFd(int fd, [String expected = '']) {
    final chunks = <List<int>>[];
    final sink = ChunkedConversionSink<Digest>.withCallback(
      (d) => chunks.add(d.single.bytes),
    );
    final input = (expected.length == 128 ? sha512 : hashes.sha256)
        .startChunkedConversion(sink);
    var offset = 0;
    while (true) {
      final block = posix.readAt(fd, offset, 1024 * 1024);
      if (block.isEmpty) break;
      input.add(block);
      offset += block.length;
    }
    input.close();
    return chunks.single.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// install_ctl.sha256_of: the digest of a file (by name).
  String digestOf(String path, [String expected = '']) {
    final fd = posix.openAt(-100, path, Posix.noFollow | Posix.cloexec);
    try {
      return digestOfFd(fd, expected);
    } finally {
      posix.close(fd);
    }
  }

  /// models_ctl._part_sizes: the parts of a split file asked for again.
  Future<List<int>> partSizes(String repo, Map<String, dynamic> entry) async {
    final paths = [for (final x in entry['paths'] as List) x as String];
    if (paths.length == 1) return [entry['size'] as int];
    final data = await hub.jsonList(
      '${hub.base}/api/models/$repo/tree/main?recursive=1',
    );
    final sizes = <dynamic, int>{};
    for (final item in data) {
      if (item is! Map) continue;
      final lfs = pyTruthy(item['lfs']) ? item['lfs'] as Map : const {};
      final value = pyTruthy(lfs['size'])
          ? lfs['size']
          : pyTruthy(item['size'])
          ? item['size']
          : 0;
      sizes[item['path']] = value is int
          ? value
          : value is double
          ? value.truncate()
          : int.parse('$value'.trim());
    }
    return [for (final path in paths) sizes[path] ?? 0];
  }

  /// models_ctl.download_gguf: every part into the target folder (a part of
  /// the right size that is our own file is kept), then the links.
  Future<String?> downloadGguf(
    String key,
    String modelsDir,
    String repo,
    Map<String, dynamic> entry,
    Progress progress,
  ) async {
    final (folder, linkDir) = ggufTarget(key, modelsDir, repo);
    Directory(folder).createSync(recursive: true);
    var done = 0;
    String? first;
    final paths = [for (final x in entry['paths'] as List) x as String];
    final sizes = await partSizes(repo, entry);
    for (var i = 0; i < math.min(paths.length, sizes.length); i++) {
      final target = p.join(folder, p.basename(paths[i]));
      first ??= target;
      if (!(ownRegularFile(target) && File(target).lengthSync() == sizes[i])) {
        await download(
          '${hub.base}/$repo/resolve/main/${pyQuote(paths[i])}',
          target,
          sizes[i],
          progress,
          doneBefore: done,
          total: entry['size'] as int,
        );
      }
      done += sizes[i];
    }
    if (linkDir != null) {
      for (final path in paths) {
        final link = p.join(linkDir, p.basename(path));
        if (!File(link).existsSync() && !Directory(link).existsSync()) {
          Link(link).createSync(p.join(folder, p.basename(path)));
        }
      }
    }
    return first;
  }

  /// model_layout.model_dir_name: `local/<this>` for a loose file.
  static String modelDirName(String fileName) {
    var stem = fileName.toLowerCase().endsWith('.gguf')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    stem = stem.replaceFirst(
      RegExp(r'-\d{5}-of-\d{5}$', caseSensitive: false),
      '',
    );
    stem = stem
        .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '-')
        .replaceFirst(RegExp(r'^[ .\-]+'), '')
        .replaceFirst(RegExp(r'[ .\-]+$'), '');
    if (stem.isEmpty) stem = 'model';
    return stem.length > 120 ? stem.substring(0, 120) : stem;
  }

  List<String> _glob(String folder, bool Function(String name) matches) {
    try {
      return [
        for (final e in Directory(folder).listSync(followLinks: false))
          if (!p.basename(e.path).startsWith('.') &&
              matches(p.basename(e.path)))
            e.path,
      ];
    } on FileSystemException {
      return [];
    }
  }

  /// models_ctl.add_local: a GGUF on this PC as a model without a second
  /// copy (a hard link on the same disk, else a symbolic one).
  String addLocal(String key, String modelsDir, String path) {
    final file = realpathLoose(path);
    if (!FileSystemEntity.isFileSync(file) ||
        !p.basename(file).toLowerCase().endsWith('.gguf')) {
      throw const FormatException('not a GGUF file');
    }
    var parts = [file];
    final split = _split.firstMatch(p.basename(file));
    if (split != null) {
      final pattern = RegExp(
        '^${RegExp.escape(split[1]!)}-.*-of-${RegExp.escape(split[3]!)}\\.gguf\$',
      );
      parts = _glob(p.dirname(file), pattern.hasMatch)..sort();
    }
    String folder;
    if (modelLayout(key) == 'publisher') {
      folder = p.join(modelsDir, 'local', modelDirName(p.basename(file)));
      parts.addAll(
        _glob(
          p.dirname(file),
          (n) => n.endsWith('.gguf') && n.toLowerCase().contains('mmproj'),
        ),
      );
    } else {
      final (target, linkDir) = ggufTarget(key, modelsDir, 'local/x');
      folder = linkDir ?? target;
    }
    Directory(folder).createSync(recursive: true);
    for (final part in parts) {
      final target = p.join(folder, p.basename(part));
      if (_lexists(target)) continue;
      if (!posix.hardLink(part, target)) Link(target).createSync(part);
    }
    return p.join(folder, p.basename(file));
  }

  /// loopback.require_own_listener.
  static void requireOwnListener(int port, int uid) {
    final owners = loopbackListeners(port);
    if (owners.isEmpty) throw const SocketException('not running');
    if (owners.any((o) => o != uid)) {
      throw StateError('port $port belongs to another user account');
    }
  }

  static int _port(String address, {int fallback = 11434}) {
    final value = address.substring(address.lastIndexOf(':') + 1);
    return value.isEmpty ? fallback : int.parse(value);
  }

  /// models_ctl.ollama_create: `ollama create` from a Modelfile naming the
  /// file; the model's name is the file's, lower case.
  Future<String> ollamaCreate(String path, String address) async {
    final file = realpathLoose(path);
    if (!FileSystemEntity.isFileSync(file) ||
        !p.basename(file).toLowerCase().endsWith('.gguf')) {
      throw const FormatException('not a GGUF file');
    }
    if (RegExp(r'["\\\x00-\x1f\x7f]').hasMatch(file)) {
      throw const FormatException(
        "the file's path has quotes, backslashes or control characters; rename it first",
      );
    }
    var base = p.basename(file).replaceFirstMapped(_split, (m) => m[1]!);
    base = base.toLowerCase();
    if (base.endsWith('.gguf')) base = base.substring(0, base.length - 5);
    var name = base
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceFirst(RegExp(r'^[\-._]+'), '')
        .replaceFirst(RegExp(r'[\-._]+$'), '');
    if (name.isEmpty) name = 'model';
    if (name.length > 100) name = name.substring(0, 100);
    final port = _port(address);
    requireOwnListener(port, posix.uid);
    final binary = _which('ollama');
    if (binary == null) throw StateError('ollama is not installed');
    final tmp = Directory.systemTemp.createTempSync('ai-agents-map-');
    try {
      final modelfile = p.join(tmp.path, 'Modelfile');
      File(modelfile).writeAsStringSync('FROM ${pyJsonDumps(file)}\n');
      final (out, ok) = await boundedOutput(
        [binary, 'create', name, '-f', modelfile],
        timeout: const Duration(seconds: 3600),
        mergeStderr: true,
        environment: {'OLLAMA_HOST': '127.0.0.1:$port'},
      );
      if (!ok) {
        final text = utf8.decode(out, allowMalformed: true).trim();
        throw StateError(
          text.isEmpty
              ? 'ollama create failed'
              : text.substring(math.max(0, text.length - 300)),
        );
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
    return name;
  }

  static String? _which(String binary) {
    for (final folder in (Platform.environment['PATH'] ?? '').split(':')) {
      if (folder.isEmpty) continue;
      final path = p.join(folder, binary);
      try {
        final st = File(path).statSync();
        if (st.type == FileSystemEntityType.file && st.mode & 0x49 != 0) {
          return path;
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// models_ctl.ollama_name_for: `hf.co/<repo>:<quant>`.
  static String ollamaNameFor(String repo, Map<String, dynamic> entry) =>
      'hf.co/$repo${'${entry['quant']}'.isNotEmpty ? ':${entry['quant']}' : ''}';

  /// models_ctl.ollama_pull_problem: why Ollama cannot pull this file.
  static String ollamaPullProblem(
    Map<String, dynamic> entry,
    List<Map<String, dynamic>> entries,
  ) {
    final paths = entry['paths'] as List;
    if (paths.length != 1) return 'split';
    if ((paths.first as String).contains('/')) return 'folder';
    final quant = '${entry['quant']}';
    if (quant.isEmpty) return 'tag';
    final same = entries.where(
      (e) => '${e['quant']}'.toUpperCase() == quant.toUpperCase(),
    );
    return same.length > 1 ? 'tag' : '';
  }

  static const pullDeadline = Duration(hours: 12);

  /// models_ctl.ollama_pull: Ollama's own download, its progress lines read
  /// within one deadline (headers in 30 s, no silence over 120 s).
  Future<void> ollamaPull(
    String name,
    String address,
    Progress progress,
  ) async {
    name = name.trim();
    if (!ModelHub.ollamaNameRe.hasMatch(name) || name.contains('..')) {
      throw const FormatException(
        'not a model name (e.g. qwen3:8b or hf.co/<user>/<repo>:Q4_K_M)',
      );
    }
    final port = _port(address);
    requireOwnListener(port, posix.uid);
    final started = DateTime.now();
    final deadline = started.add(pullDeadline);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client
          .postUrl(Uri.parse('http://127.0.0.1:$port/api/pull'))
          .timeout(const Duration(seconds: 30));
      final body = utf8.encode(jsonEncode({'model': name, 'stream': true}));
      request.persistentConnection = false;
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('the server answered ${response.statusCode}');
      }
      final pending = <int>[];
      var lines = 0;
      final stream = response.timeout(
        const Duration(seconds: 120),
        onTimeout: (sink) =>
            sink.addError(TimeoutException('no answer for 120 s')),
      );
      await for (final chunk in stream) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('the download took too long');
        }
        pending.addAll(chunk);
        while (true) {
          final end = pending.indexOf(10);
          if (end < 0) {
            if (pending.length > 65536) {
              throw const FormatException('a reply line over 65536 bytes');
            }
            break;
          }
          if (end + 1 > 65536) {
            throw const FormatException('a reply line over 65536 bytes');
          }
          final raw = pending.sublist(0, end + 1);
          pending.removeRange(0, end + 1);
          if (++lines > 200000) {
            throw const FormatException('more than 200000 reply lines');
          }
          if (_pullLine(raw, progress)) return;
        }
      }
      if (pending.isNotEmpty && _pullLine(pending, progress)) return;
    } on TimeoutException catch (error) {
      throw StateError('the download took too long ($error)');
    } finally {
      client.close(force: true);
    }
    throw StateError('the download stopped before it was finished');
  }

  /// One progress line of a pull; true when it says success.
  static bool _pullLine(List<int> raw, Progress progress) {
    dynamic line;
    try {
      line = jsonDecode(utf8.decode(raw, allowMalformed: true));
    } on FormatException {
      return false;
    }
    if (line is! Map) return false;
    if (pyTruthy(line['error'])) {
      final text = '${line['error']}';
      throw StateError(text.length > 2000 ? text.substring(0, 2000) : text);
    }
    final total = line['total'], completed = line['completed'];
    final fraction = total is int && total > 0 && completed is int
        ? completed / total
        : 0.0;
    final status = line.containsKey('status') ? pyStr(line['status']) : '';
    progress(fraction, status.length > 120 ? status.substring(0, 120) : status);
    return line['status'] == 'success';
  }
}
