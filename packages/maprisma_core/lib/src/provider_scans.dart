import 'dart:io';
import 'package:path/path.dart' as p;
import 'agent_details.dart';
import 'scan_files.dart';
import 'strata.dart';
import 'provider_facts.dart';

String cleanName(dynamic value) {
  if (value is! String) return '';
  final text = value.trim();
  if (text.isNotEmpty &&
      !RegExp(
        r'^[\p{L}\p{N}_.@:+/ \-]{1,120}$',
        unicode: true,
      ).hasMatch(text)) {
    return '';
  }
  return boundedText(text, 120);
}

String tilde(ScanFiles files, String path) => path == files.identity.home
    ? '~'
    : p.isWithin(files.identity.home, path)
    ? '~/${p.relative(path, from: files.identity.home)}'
    : path;

final class ProcessRecord {
  ProcessRecord(this.pid, this.comm, this.argv);
  final int pid;
  final String comm;
  final List<String> argv;
}

final class RuntimeRecord {
  RuntimeRecord(this.key, this.name);
  final String key, name;
  bool installed = false, running = false, serverOff = false;
  String service = '', address = '', modelsDir = '';
  List<String> models = [], agents = [], activeAgents = [];

  /// The absolute paths of the model files it serves outside [modelsDir],
  /// where its scan knows them (llama.cpp's -m and models.ini, KoboldCpp's
  /// model, vLLM's served file): a reused folder compares them by file
  /// identity. Not in [toJson].
  List<String> modelFiles = [];
  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'installed': installed,
    'running': running,
    'service': service,
    'address': address,
    'models_dir': modelsDir,
    'models': models,
    'agents': agents,
    'active_agents': activeAgents,
    'server_off': serverOff,
  };
}

final _portText = RegExp(r'^[0-9]{1,5}$');

/// gpu_usage.port_number: a port written as text, 1-5 ASCII digits in
/// 1..65535; 0 for anything else, so no scan or address fails on it.
int portNumber(String text) {
  if (!_portText.hasMatch(text)) return 0;
  final port = int.parse(text);
  return port > 0 && port < 65536 ? port : 0;
}

/// The port of a runtime's address ("127.0.0.1:9090", "http://host:9090/"),
/// or null.
int? addressPort(String address) {
  final m = RegExp(r':(\d{1,5})/?$').firstMatch(address.trim());
  return m == null ? null : int.parse(m[1]!);
}

/// The local LLM an agent's local provider points at: the installed one
/// whose detected address has the configured port, else the one whose usual
/// port it is (the provider's `runtime`, from the facts) while its address is
/// unknown or that port. One detected on another port is not there: the
/// provider's endpoint is stale ([movedRuntime]).
RuntimeRecord? localRuntime(Map provider, Iterable<RuntimeRecord> runtimes) {
  if (provider['local'] != true) return null;
  final port = provider['port'];
  final usual = _usualRuntime(provider, runtimes);
  if (port is int) {
    // Two local LLMs may share a usual port (Strata and llama.cpp: 8080):
    // the one the provider names wins, else the first one detected there.
    final here = [
      for (final rt in runtimes)
        if (rt.installed && addressPort(rt.address) == port) rt,
    ];
    if (here.isNotEmpty) return here.contains(usual) ? usual : here.first;
  }
  return usual == null || _moved(usual, port) ? null : usual;
}

/// The local LLM whose usual port a local provider has, while it was detected
/// on another one (llama.cpp on 9090, the agent still set to 8080): a broken
/// line to it, not a working one.
RuntimeRecord? movedRuntime(Map provider, Iterable<RuntimeRecord> runtimes) {
  if (provider['local'] != true || localRuntime(provider, runtimes) != null) {
    return null;
  }
  final usual = _usualRuntime(provider, runtimes);
  return usual != null && usual.installed && _moved(usual, provider['port'])
      ? usual
      : null;
}

RuntimeRecord? _usualRuntime(Map provider, Iterable<RuntimeRecord> runtimes) {
  for (final rt in runtimes) {
    if (rt.name == provider['runtime']) return rt;
  }
  return null;
}

bool _moved(RuntimeRecord rt, Object? port) {
  final at = addressPort(rt.address);
  return port is int && at != null && at != port;
}

final class ProviderScans {
  ProviderScans(this.files);
  final ScanFiles files;
  String get proc =>
      files.identity.environment['MAPRISMA_SCAN_PROC'] ?? '/proc';
  List<ProcessRecord> processes() {
    final found = <ProcessRecord>[];
    for (final path in files.list(proc, limit: 4000, allowRootOwned: true)) {
      final pid = int.tryParse(p.basename(path));
      if (pid == null) continue;
      final comm = files.text('$path/comm', limit: 65536);
      if (comm == null) continue;
      final cmd = files.text('$path/cmdline', limit: 65536);
      if (cmd == null) continue;
      found.add(
        ProcessRecord(
          pid,
          comm.trim(),
          cmd.split('\x00').where((a) => a.isNotEmpty).toList(),
        ),
      );
    }
    return found;
  }

  /// inventory.parent_pid.
  int parentPid(int pid) {
    final stat = files.text('$proc/$pid/stat', limit: 1024) ?? '';
    final fields = stat
        .substring(stat.lastIndexOf(')') + 1)
        .trim()
        .split(RegExp(r'\s+'));
    return fields.length > 1 ? int.tryParse(fields[1]) ?? 0 : 0;
  }

  Map<String, String> processEnv(int pid, Set<String> allowed) {
    final text = files.text('$proc/$pid/environ', limit: 256 * 1024) ?? '';
    final found = <String, String>{};
    for (final entry in text.split('\x00')) {
      final at = entry.indexOf('=');
      if (at < 0) continue;
      final key = entry.substring(0, at);
      if (allowed.contains(key)) found[key] = entry.substring(at + 1);
    }
    return found;
  }

  bool which(String binary) {
    for (final folder in (files.identity.environment['PATH'] ?? '').split(
      ':',
    )) {
      if (folder.isEmpty) continue;
      try {
        final path = p.join(folder, binary);
        final info = File(path).statSync();
        if (info.type == FileSystemEntityType.file && info.mode & 0x49 != 0) {
          return true;
        }
      } on FileSystemException {
        /* next directory */
      }
    }
    return false;
  }

  String arg(List<String> argv, List<String> flags) {
    for (var i = 0; i < argv.length; i++) {
      for (final flag in flags) {
        if (argv[i] == flag && i + 1 < argv.length) return argv[i + 1];
        if (argv[i].startsWith('$flag=')) {
          return argv[i].substring(flag.length + 1);
        }
      }
    }
    return '';
  }

  static const environmentKeys = {
    'LLAMA_ARG_MODELS_DIR',
    'LLAMA_MODELS_DIR',
    'LLAMA_ARG_MODEL',
    'LLAMA_ARG_HOST',
    'LLAMA_ARG_PORT',
    'LLAMA_PORT',
    'LLAMA_HOST',
    'OLLAMA_MODELS',
    'OLLAMA_HOST',
    'VLLM_MODEL',
    'KOBOLDCPP_MODELS',
  };
  (String, Map<String, String>) unit(String binary, {bool named = false}) {
    final entries =
        named
              ? [files.expand('~/.config/systemd/user/$binary.service')]
              : files
                    .list('~/.config/systemd/user', limit: 4000)
                    .where((s) => s.endsWith('.service'))
                    .toList()
          ..sort();
    for (final path in entries.take(200)) {
      var text = files.text(path) ?? '';
      if (!named) {
        final extras =
            files
                .list('$path.d', limit: 4000)
                .where((s) => s.endsWith('.conf'))
                .toList()
              ..sort();
        for (final extra in extras.take(20)) {
          text += '\n${files.text(extra) ?? ''}';
        }
      }
      if (text.isEmpty) continue;
      if (!named &&
          !RegExp(
            r'^ExecStart=[-@:+!]*"?\S*?([^/\s"]+)"?(?:\s|$)',
            multiLine: true,
          ).allMatches(text).any((m) => m[1] == binary)) {
        continue;
      }
      final env = <String, String>{};
      for (final match in RegExp(
        r'^EnvironmentFile=-?(.+)$',
        multiLine: true,
      ).allMatches(text).take(10)) {
        final file = files.expand(
          match[1]!.trim().replaceAll('%h', files.identity.home),
        );
        for (final value in RegExp(
          r'^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$',
          multiLine: true,
        ).allMatches(files.text(file) ?? '')) {
          if (environmentKeys.contains(value[1])) {
            env[value[1]!] = value[2]!.trim().replaceAll(
              RegExp('^[\'"]+|[\'"]+\$'),
              '',
            );
          }
        }
      }
      if (!named) {
        for (final line in RegExp(
          r'^Environment=(.+)$',
          multiLine: true,
        ).allMatches(text).take(20)) {
          for (final match in RegExp(
            r'"?([A-Z_][A-Z0-9_]*)=([^"\s]*)"?',
          ).allMatches(line[1]!)) {
            if (environmentKeys.contains(match[1])) env[match[1]!] = match[2]!;
          }
        }
      }
      return (p.basenameWithoutExtension(path), env);
    }
    return ('', {});
  }

  List<String> dedupe(Iterable<String> names) {
    final out = <String>[];
    for (final name in names) {
      final clean = cleanName(name);
      if (clean.isNotEmpty && !out.contains(clean)) out.add(clean);
      if (out.length == 500) break;
    }
    return out;
  }

  List<String> ggufNames(String folder) =>
      ggufFiles(folder).map(ggufName).toSet().take(500).toList();

  /// A GGUF file's model name.
  static String ggufName(String file) {
    final name = p.basename(file);
    return name.substring(0, name.length - 5);
  }

  /// The GGUF files of a folder (or links to them), one level deep.
  List<String> ggufFiles(String folder) {
    final found = <String>[];
    final entries = files.list(folder, limit: 4000)..sort();
    for (final entry in entries.take(1000)) {
      final name = p.basename(entry), lower = p.basename(entry).toLowerCase();
      if (lower.endsWith('.gguf') && !lower.startsWith('mmproj')) {
        found.add(entry);
      } else if (!name.startsWith('.') &&
          FileSystemEntity.typeSync(entry) == FileSystemEntityType.directory) {
        for (final file in files.list(entry, limit: 50)) {
          final lower = p.basename(file).toLowerCase();
          if (lower.endsWith('.gguf') && !lower.startsWith('mmproj')) {
            found.add(file);
          }
        }
      }
    }
    return found;
  }

  /// The `model = <path>` files of a preset file's sections (llama.cpp's
  /// models.ini), absolute.
  List<String> presetFiles(String path) => absoluteFiles(
    RegExp(
      r'^\s*model\s*=\s*"?([^"\n]+?)"?\s*$',
      multiLine: true,
    ).allMatches(files.text(path) ?? '').map((m) => m[1]!),
  );

  /// Model paths as files of this PC: `~` expanded, relative ones dropped.
  List<String> absoluteFiles(Iterable<String> paths) => {
    for (final path in paths)
      if (p.isAbsolute(files.expand(path.trim())))
        p.normalize(files.expand(path.trim())),
  }.take(500).toList();

  List<String> presets(String path) =>
      RegExp(r'^\[([^\]\n]{1,120})\]', multiLine: true)
          .allMatches(files.text(path) ?? '')
          .map((m) => m[1]!)
          .where((s) => s != '*')
          .toList();
  List<String> ollamaModels(String root) {
    final found = <String>[];
    for (final store in ['manifests', 'manifests-v2']) {
      final hosts = files.list('$root/$store')..sort();
      for (final host in hosts.take(20)) {
        final owners = files.list(host)..sort();
        for (final owner in owners.take(200)) {
          final models = files.list(owner)..sort();
          for (final model in models.take(500)) {
            final tags = files.list(model)..sort();
            for (final tag in tags.take(50)) {
              final plain = [
                'registry.ollama.ai',
                'ollama.com',
              ].contains(p.basename(host));
              final prefix = plain && p.basename(owner) == 'library'
                  ? ''
                  : plain
                  ? '${p.basename(owner)}/'
                  : '${p.basename(host)}/${p.basename(owner)}/';
              final name = '$prefix${p.basename(model)}:${p.basename(tag)}';
              if (!found.contains(name)) found.add(name);
              if (found.length >= 500) return found;
            }
          }
        }
      }
    }
    return found;
  }

  /// The local LLMs' detection: the visible ones, or the given facts (the
  /// System Map also looks at built-in ones an add-on hides).
  List<RuntimeRecord> scan({List? facts}) {
    final processesNow = processes(), result = <RuntimeRecord>[];
    for (final fact in facts ?? visibleProviderFacts['local'] as List) {
      final key = fact['key'] as String,
          rt = RuntimeRecord(fact['key'], fact['name']);
      switch (key) {
        case 'llamacpp':
          rt.installed = which('llama-server');
          final (service, env) = unit('llama-server');
          rt.service = service;
          var folder = '';
          final models = <String>[], served = <String>[];
          bool server(ProcessRecord process) =>
              process.comm == 'llama-server' &&
              !(process.argv.isNotEmpty &&
                  process.argv[0].contains('/.lmstudio/'));
          final servers = {
            for (final process in processesNow)
              if (server(process)) process.pid,
          };
          for (final process in processesNow) {
            if (!server(process)) continue;
            rt.running = rt.installed = true;
            // A model the router started on a port of its own: the router is
            // the address (inventory.llamacpp).
            if (servers.contains(parentPid(process.pid))) continue;
            env.addAll(processEnv(process.pid, environmentKeys));
            final model = arg(process.argv, ['-m', '--model']);
            if (model.isNotEmpty) {
              models.add(
                p.basename(model).replaceFirst(RegExp(r'\.gguf$'), ''),
              );
              served.add(model);
            }
            folder = arg(process.argv, ['--models-dir']).isNotEmpty
                ? arg(process.argv, ['--models-dir'])
                : folder;
            rt.address =
                '${arg(process.argv, ['--host']).isNotEmpty ? arg(process.argv, ['--host']) : env['LLAMA_ARG_HOST'] ?? env['LLAMA_HOST'] ?? '127.0.0.1'}:${arg(process.argv, ['--port']).isNotEmpty ? arg(process.argv, ['--port']) : env['LLAMA_ARG_PORT'] ?? env['LLAMA_PORT'] ?? '8080'}';
          }
          folder = folder.isNotEmpty
              ? folder
              : env['LLAMA_ARG_MODELS_DIR'] ?? env['LLAMA_MODELS_DIR'] ?? '';
          if (rt.address.isEmpty &&
              (env.containsKey('LLAMA_PORT') ||
                  env.containsKey('LLAMA_ARG_PORT'))) {
            rt.address =
                '${env['LLAMA_HOST'] ?? env['LLAMA_ARG_HOST'] ?? '127.0.0.1'}:${env['LLAMA_PORT'] ?? env['LLAMA_ARG_PORT']}';
          }
          if (folder.isNotEmpty) {
            rt.modelsDir = tilde(files, files.expand(folder));
            models.addAll(ggufNames(files.expand(folder)));
          }
          rt.models = dedupe([
            ...models,
            ...presets('~/.config/llama.cpp/models.ini'),
            ...ggufNames('~/.cache/llama.cpp'),
          ]);
          rt.modelFiles = absoluteFiles([
            ...served,
            ?env['LLAMA_ARG_MODEL'],
            ...presetFiles('~/.config/llama.cpp/models.ini'),
            ...ggufFiles(files.expand('~/.cache/llama.cpp')),
          ]);
          rt.installed = rt.installed || rt.service.isNotEmpty;
        case 'ollama':
          rt.installed = which('ollama');
          final (service, env) = unit('ollama');
          rt.service = service;
          for (final process in processesNow) {
            if (process.comm == 'ollama' &&
                process.argv.skip(1).take(2).contains('serve')) {
              rt.running = rt.installed = true;
              env.addAll(
                processEnv(process.pid, {'OLLAMA_MODELS', 'OLLAMA_HOST'}),
              );
            }
          }
          rt.address = env['OLLAMA_HOST'] ?? '127.0.0.1:11434';
          final system =
              files.identity.environment['MAPRISMA_SCAN_SYSTEM_ROOT'] ?? '';
          for (final path in [
            if (env['OLLAMA_MODELS'] != null)
              files.expand(env['OLLAMA_MODELS']!),
            files.expand('~/.ollama/models'),
            '$system/var/lib/ollama/.ollama/models',
            '$system/var/lib/ollama',
          ]) {
            if (Directory('$path/manifests').existsSync() ||
                Directory('$path/manifests-v2').existsSync()) {
              rt.modelsDir = tilde(files, path);
              rt.models = ollamaModels(path);
              break;
            }
          }
          rt.installed = rt.installed || rt.service.isNotEmpty;
        case 'lmstudio':
          final root = files.expand('~/.lmstudio');
          rt.installed = Directory(root).existsSync() || which('lms');
          // Its server's port, when set in the app (Developer › Settings).
          final server = files.json('$root/.internal/http-server-config.json');
          final port = server['port'] is int && server['port'] > 0
              ? server['port'] as int
              : 1234;
          rt.address = '127.0.0.1:$port';
          for (final process in processesNow) {
            if (process.comm.toLowerCase().startsWith('lm studio') ||
                process.comm == 'lm-studio' ||
                process.argv.isNotEmpty &&
                    [
                      'lm-studio',
                      'lm studio',
                    ].contains(p.basename(process.argv[0]).toLowerCase())) {
              rt.running = true;
            }
          }
          final config = files.json('$root/settings.json');
          final configured = config['downloadsFolder'];
          final path = configured is String && configured.isNotEmpty
              ? files.expand(configured)
              : '$root/models';
          final names = <String>[], publishers = files.list(path)..sort();
          for (final publisher in publishers.take(200)) {
            if (p.basename(publisher).startsWith('.')) continue;
            final repos = files.list(publisher)..sort();
            for (final repo in repos.take(500)) {
              if (files
                  .list(repo, limit: 200)
                  .any(
                    (s) => s.endsWith('.gguf') || s.endsWith('.safetensors'),
                  )) {
                names.add(p.basename(repo));
              }
            }
          }
          if (names.isNotEmpty) rt.modelsDir = tilde(files, path);
          final index = files.json(
            '$root/.internal/model-index-cache.json',
            limit: 32 * 1024 * 1024,
          )['models'];
          final ids = <String>[];
          if (index is List) {
            for (final entry in index.take(500)) {
              if (entry is! Map ||
                  entry['domain'] != 'llm' ||
                  entry['defaultIdentifier'] is! String) {
                continue;
              }
              final abs = dig(entry, 'entryPoint.absPath');
              if (abs is String && !files.exists(abs)) continue;
              final name = cleanName(entry['defaultIdentifier']);
              if (name.isNotEmpty) ids.add(name);
            }
          }
          rt.models = dedupe(ids.isNotEmpty ? ids : names);
          if (rt.running) rt.serverOff = !listeners(port);
        case 'vllm':
          rt.installed = which('vllm');
          rt.address = '127.0.0.1:8000';
          final (service, env) = unit('vllm');
          rt.service = service;
          rt.installed = rt.installed || service.isNotEmpty;
          if (cleanName(env['VLLM_MODEL']).isNotEmpty) {
            rt.models = [cleanName(env['VLLM_MODEL'])];
          }
          // A model given as a file of this PC (a GGUF), not a hub name.
          final servedFiles = [?env['VLLM_MODEL']];
          for (final process in processesNow) {
            final argv = process.argv;
            if (argv.length > 2 &&
                (p.basename(argv[0]).startsWith('vllm') ||
                    p.basename(argv[0]).startsWith('python')) &&
                argv.skip(1).take(2).contains('serve') &&
                argv.take(4).any((a) => p.basename(a) == 'vllm')) {
              rt.running = rt.installed = true;
              final model = arg(argv, ['--model']);
              final serve = argv.indexOf('serve');
              final named = model.isNotEmpty
                  ? model
                  : serve + 1 < argv.length
                  ? argv[serve + 1]
                  : '';
              rt.models = dedupe([named]);
              servedFiles.addAll([
                model,
                if (serve + 1 < argv.length) argv[serve + 1],
              ]);
              final host = arg(argv, ['--host']), port = arg(argv, ['--port']);
              rt.address =
                  '${host.isEmpty ? '127.0.0.1' : host}:${port.isEmpty ? '8000' : port}';
            }
          }
          rt.modelFiles = absoluteFiles(servedFiles);
        case 'jan':
          rt.service = unit('jan', named: true).$1;
          // The port its service starts the engine on, else the usual one.
          var port = RegExp(r'--port[= ]+(\d{1,5})\b').firstMatch(
            rt.service.isEmpty
                ? ''
                : files.text('~/.config/systemd/user/jan.service') ?? '',
          )?[1];
          final root = files.expand('~/.local/share/Jan');
          rt.installed =
              rt.service.isNotEmpty ||
              Directory(root).existsSync() ||
              which('jan');
          for (final process in processesNow) {
            if (process.comm == 'jan-llama-worke' ||
                process.argv.isNotEmpty &&
                    p.basename(process.argv[0]) == 'jan-llama-worker') {
              rt.installed = true;
              // The router (it has a preset; a model's own worker has none)
              // on whatever port it was started.
              final at = arg(process.argv, ['--port']);
              if (RegExp(r'^\d{1,5}$').hasMatch(at) &&
                  (at == (port ?? '6767') ||
                      arg(process.argv, ['--preset']).isNotEmpty)) {
                rt.running = true;
                port = at;
              }
            }
          }
          rt.address = '127.0.0.1:${port ?? 6767}';
          final value = files.json('$root/settings.json')['data_folder'];
          final folder = value is String && value.trim().isNotEmpty
              ? (p.isAbsolute(files.expand(value.trim()))
                    ? files.expand(value.trim())
                    : p.join(root, value.trim()))
              : '$root/data';
          final modelDir = '$folder/llamacpp/models';
          if (Directory(modelDir).existsSync()) {
            rt.modelsDir = tilde(files, modelDir);
          }
          final names = presets('$folder/llamacpp/router.preset.ini'),
              entries = files.list(modelDir)..sort();
          for (final entry in entries.take(500)) {
            if (p.basename(entry).startsWith('.')) continue;
            if (files.exists('$entry/model.yml')) {
              names.add(p.basename(entry));
              continue;
            }
            final inner = files.list(entry)..sort();
            for (final child in inner.take(100)) {
              if (files.exists('$child/model.yml')) {
                names.add('${p.basename(entry)}/${p.basename(child)}');
              }
            }
          }
          rt.models = dedupe(names);
        case 'koboldcpp':
          rt.address = '127.0.0.1:5001';
          final (service, env) = unit('koboldcpp', named: true);
          rt.service = service;
          rt.installed = service.isNotEmpty || which('koboldcpp');
          final servedFiles = <String>[];
          for (final process in processesNow) {
            if (process.comm == 'koboldcpp' ||
                process.argv.isNotEmpty &&
                    p.basename(process.argv[0]).startsWith('koboldcpp')) {
              rt.running = rt.installed = true;
              servedFiles.add(arg(process.argv, ['--model', '--model_param']));
              final port = arg(process.argv, ['--port']);
              if (portNumber(port) != 0) rt.address = '127.0.0.1:$port';
            }
          }
          if (env['KOBOLDCPP_MODELS'] != null) {
            rt.modelsDir = tilde(files, files.expand(env['KOBOLDCPP_MODELS']!));
          }
          final names =
              files
                  .list('~/.config/koboldcpp/models')
                  .map(p.basename)
                  .where((s) => s.endsWith('.kcpps'))
                  .toList()
                ..sort();
          rt.models = dedupe(names);
          // Each .kcpps names its model file (model_param, or model).
          for (final name in names.take(500)) {
            final config = files.json('~/.config/koboldcpp/models/$name');
            for (final key in ['model_param', 'model']) {
              final value = config[key];
              for (final path in value is List ? value : [value]) {
                if (path is String && path.isNotEmpty) servedFiles.add(path);
              }
            }
          }
          rt.modelFiles = absoluteFiles(servedFiles);
        case 'strata':
          // inventory.strata: its own CLI, its server process (the port from
          // its run config), its run configs as models; while it is off, the
          // port of the launch preset used last.
          final strata = StrataFacts(files);
          rt.installed = strata.binary() != null;
          var port = 0;
          for (final process in processesNow) {
            if (StrataFacts.isServer(process.argv)) {
              rt.running = rt.installed = true;
              if (port == 0) port = strata.serverPort(process.argv);
            }
          }
          if (port == 0) port = strata.lastPreset().$2;
          rt.address =
              '127.0.0.1:${port == 0 ? StrataFacts.defaultPort : port}';
          final names = strata.modelIds();
          if (names.isNotEmpty) rt.modelsDir = tilde(files, strata.installDir);
          rt.models = dedupe(names);
      }
      result.add(rt);
    }
    return result;
  }

  bool listeners(int port) {
    for (final path in ['$proc/net/tcp', '$proc/net/tcp6']) {
      final source = files.text(path, allowRootOwned: true) ?? '';
      for (final line in source.split('\n').skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 8 || fields[3] != '0A') continue;
        final local = fields[1].split(':');
        if (local.length == 2 &&
            int.tryParse(local[1], radix: 16) == port &&
            int.tryParse(fields[7]) == files.posix.uid) {
          return true;
        }
      }
    }
    return false;
  }
}
