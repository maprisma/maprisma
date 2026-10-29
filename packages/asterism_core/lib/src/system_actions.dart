import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'agent_actions.dart' show Recipes, Step;
import 'agent_catalog.dart';
import 'connect_apply.dart';
import 'desktop.dart' show Desktop, shellQuote;
import 'existing_ai.dart' as existing_ai;
import 'installers.dart' show InstallHost, LlamaCppInstaller, OllamaInstaller;
import 'posix_ffi.dart';
import 'provider_scans.dart' show RuntimeRecord;
import 'system_map.dart' show detectTools, gpuStack, hardware;

/// The System Map's actions on supporting tools, the GPU stack and model
/// folders (system_tools.check_record / check, StackActions, the local LLMs'
/// model_folder_changes).

/// system_tools.check_record: a supporting tool as a program to check.
Map<String, dynamic> toolCheckRecord(
  dynamic node,
  Map<String, String> env,
  AgentCatalog catalog,
) {
  if (node is! String || !node.startsWith('tool:')) {
    throw const FormatException('Unknown supporting tool');
  }
  final row = detectTools(
    env,
    catalog,
  ).where((r) => 'tool:${r['key']}' == node && r['key'] != 'venv').firstOrNull;
  if (row == null) throw const FormatException('Supporting tool unavailable');
  return {
    'kind': 'runtime',
    'path': row['target'],
    'key': row['key'],
    'environment': <String, String>{},
    'stamp': existing_ai.stamp(row['target'] as String),
  };
}

/// system_tools.check: the tool unchanged since the preview, then its own
/// --version as flutter_existing.check runs it.
Future<Map<String, dynamic>> checkTool(
  List<int> body,
  Map<String, String> env,
  AgentCatalog catalog,
) {
  final record = jsonDecode(utf8.decode(body)) as Map;
  return existing_ai.checkProgram(
    record,
    validator: (_) {
      final fresh = toolCheckRecord('tool:${record['key']}', env, catalog);
      if (jsonEncode(fresh) != jsonEncode(record)) {
        throw const FormatException('Supporting tool changed; refresh first');
      }
    },
  );
}

/// gpu_stack.ways: the pacman package, then the vendor's page.
const _stackPackages = {
  'rocm': (
    'ROCm',
    'rocm-hip-runtime',
    'https://rocm.docs.amd.com/projects/install-on-linux/en/latest/',
  ),
  'pytorch-rocm': (
    'PyTorch for ROCm',
    'python-pytorch-rocm',
    'https://pytorch.org/get-started/locally/',
  ),
  'vulkan-radeon': (
    'Vulkan for AMD cards',
    'vulkan-radeon',
    'https://docs.mesa3d.org/drivers/radv.html',
  ),
};

List<Map<String, dynamic>> stackWays(String key) {
  final (name, package, page) = _stackPackages[key]!;
  return [
    {
      'kind': 'package',
      'packages': [
        ['pacman', package],
      ],
    },
    {
      'kind': 'manual',
      'url': page,
      'note': 'Install $name as its vendor describes for your distribution.',
    },
  ];
}

String _stepJson(Step s) => jsonEncode({
  'kind': s.kind,
  'commands': s.commands,
  'run': s.run,
  'sudo': s.sudo,
  'installer': s.installer,
  'url': s.url,
  'note': s.note,
});

/// system_tools.StackActions: what the GPU stack misses, installed through
/// the usual way in a terminal the user watches.
final class StackActions {
  StackActions(
    this.env,
    this.home,
    this.desktop,
    this.newToken,
    this.translate,
  );
  final Map<String, String> env;
  final String home;
  final Desktop desktop;
  final String Function() newToken;
  final String Function(String) translate;
  final previews = <String, (DateTime, String, String)>{};

  Step resolve(dynamic part) {
    final gpus = (hardware()['gpus'] as List).cast<Map>();
    final vendor =
        gpus
            .where((g) => g['vendor'] == 'amd')
            .map((g) => '${g['vendor']}')
            .firstOrNull ??
        (gpus.isNotEmpty ? '${gpus.first['vendor']}' : '');
    final wanted =
        (gpuStack(vendor, env, home)['stack'] as Map)['missing'] as List;
    if (part is! String || !wanted.contains(part)) {
      throw const FormatException('GPU stack action unavailable');
    }
    final step = Recipes(env['PATH']).choose(stackWays(part), 'install', '');
    if (step == null || (step.run == null && step.url.isEmpty)) {
      throw const FormatException('No supported installation action');
    }
    return step;
  }

  Map<String, dynamic> preview(dynamic part) {
    final step = resolve(part);
    final now = DateTime.now();
    previews.removeWhere((_, v) => now.difference(v.$1).inSeconds >= 600);
    while (previews.length >= 8) {
      previews.remove(previews.keys.first);
    }
    final token = newToken();
    previews[token] = (now, part as String, _stepJson(step));
    return {
      'preview': token,
      'files': [],
      'notes': step.note.isNotEmpty
          ? ["Follow the vendor's instructions for this distribution."]
          : [],
      'commands': step.commands,
      'url': step.url,
      'empty': false,
    };
  }

  Map<String, dynamic> apply(dynamic token) {
    final kept = token is String ? previews[token] : null;
    if (kept == null) throw const FormatException('Unknown stack preview');
    final step = resolve(kept.$2);
    if (DateTime.now().difference(kept.$1).inSeconds >= 600 ||
        _stepJson(step) != kept.$3) {
      throw const FormatException('GPU stack preview changed');
    }
    if (step.run == null ||
        !desktop.runStepsInTerminal(
          step.run!,
          translate('Done. Press Enter to close.'),
        )) {
      throw const FormatException('No terminal available');
    }
    previews.remove(token);
    return {'external': true};
  }
}

/// llm_engine.env_with: NAME=value set in an environment file's text.
String envWith(String text, String name, String value) {
  final line = '$name=$value';
  final re = RegExp(
    '^\\s*(?:export\\s+)?${RegExp.escape(name)}=.*\$',
    multiLine: true,
  );
  if (re.hasMatch(text)) return text.replaceFirst(re, line);
  return '$text${text.endsWith('\n') || text.isEmpty ? '' : '\n'}$line\n';
}

/// The providers' model_folder_changes (Ollama, llama.cpp): their settings
/// file, and a wrapper the app connected, pointed at another model folder.
List<Change> modelFolderChanges(
  RuntimeRecord rt,
  String folder,
  String home,
  Posix posix,
  ConfigFiles config,
) {
  if (const ['\\', '"', '\n', '\r'].any(folder.contains)) {
    throw const FormatException('Unsupported model-folder quoting');
  }
  final host = InstallHost(home, posix);
  final String env, variable, wrapperArg, before;
  final String? installed;
  if (rt.key == 'ollama') {
    if (!FileSystemEntity.isDirectorySync('$folder/blobs') ||
        ![
          'manifests',
          'manifests-v2',
        ].any((n) => FileSystemEntity.isDirectorySync('$folder/$n'))) {
      throw const FormatException('Choose an Ollama model store');
    }
    final inst = OllamaInstaller(host);
    env = inst.envFile;
    variable = 'OLLAMA_MODELS';
    installed = inst.installedFolder();
    before = 'export OLLAMA_MODELS=${shellQuote(rt.modelsDir)}';
    wrapperArg = 'export OLLAMA_MODELS=${shellQuote(folder)}';
  } else if (rt.key == 'llamacpp') {
    final inst = LlamaCppInstaller(host);
    env = inst.envFile;
    variable = 'LLAMA_ARG_MODELS_DIR';
    installed = inst.installedFolder();
    final dir = rt.modelsDir == '~' || rt.modelsDir.startsWith('~/')
        ? '$home${rt.modelsDir.substring(1)}'
        : rt.modelsDir;
    before = '--models-dir ${shellQuote(dir)}';
    wrapperArg = '--models-dir ${shellQuote(folder)}';
  } else {
    throw const FormatException('No safe model-folder configuration');
  }
  if (FileSystemEntity.isLinkSync(env)) {
    throw const FormatException('Environment file is a symbolic link');
  }
  final old = config.read(env);
  if (old.isEmpty) {
    throw const FormatException('No editable provider environment');
  }
  final changes = [Change(env, old, envWith(old, variable, folder))];
  final link = p.join(
    home,
    '.local/bin',
    rt.key == 'ollama' ? 'ollama' : 'llama-server',
  );
  if (!FileSystemEntity.isLinkSync(link) && FileSystemEntity.isFileSync(link)) {
    final text = config.read(link);
    if (!text.contains('# Connected by Asterism')) {
      throw const FormatException('Use AI help to review this custom wrapper');
    }
    if (!text.contains(before)) {
      throw const FormatException('Wrapper model path changed');
    }
    changes.add(Change(link, text, text.replaceFirst(before, wrapperArg)));
  } else if (installed == null) {
    throw const FormatException('Runtime is not managed here');
  }
  return changes;
}
