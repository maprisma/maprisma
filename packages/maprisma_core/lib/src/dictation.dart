import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'desktop.dart';
import 'health_report.dart' show voiceRe;
import 'identity.dart';
import 'protocol.dart' show ServiceError;
import 'read_service.dart';
import 'service_i18n.dart';
import 'settings.dart';

const whisperStarterModels = <Map<String, dynamic>>[
  {
    'id': 'base',
    'file': 'ggml-base.bin',
    'label': 'Whisper base (148 MB · fast, any PC)',
    'size_mb': 148,
    'url':
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin',
  },
  {
    'id': 'small',
    'file': 'ggml-small.bin',
    'label': 'Whisper small (488 MB · balanced)',
    'size_mb': 488,
    'url':
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin',
  },
  {
    'id': 'turbo',
    'file': 'ggml-large-v3-turbo-q5_0.bin',
    'label': 'Whisper large-v3-turbo (574 MB · best accuracy)',
    'size_mb': 574,
    'url':
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin',
  },
];

final _whisperGgmlRe = RegExp(
  r'^ggml-(tiny|base|small|medium|large(-v[123])?(-turbo)?)(\.en)?(-q[0-9]_[0-9k])?\.bin$',
);

/// Only real Whisper GGML/GGUF files count as Whisper models, never general
/// `ggml-*.bin` LLM weights in `models_root` or `model_folders` or `.part`
/// partial downloads.
bool isWhisperModelFile(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.part')) return false;
  return _whisperGgmlRe.hasMatch(lower) ||
      (lower.contains('whisper') &&
          (lower.endsWith('.bin') || lower.endsWith('.gguf')));
}

final class DictationService {
  DictationService(
    this.identity,
    this.settings,
    this.desktop,
    this.i18n,
    this.reads,
  );

  final AppIdentity identity;
  final SettingsStore settings;
  final Desktop desktop;
  final ServiceI18n i18n;
  final ReadService reads;

  String? _recordingId;
  String? _recordingMode;
  String? _activeEngine;
  Directory? _recordingDir;
  String? _recordingWav;
  int? _recordingPid;
  Process? _recorderProcess;
  bool _transcribing = false;
  final List<Map<String, dynamic>> testActions = [];

  String get _managedWhisperDir =>
      p.join(identity.dataDir, 'whisper', 'models');

  String? _which(String program) =>
      whichIn(program, identity.environment['PATH']);

  Map<String, dynamic>? _testFixture() {
    final raw = identity.environment['MAPRISMA_TEST_DICTATION'];
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Stops and cleans up any active recording when the core shuts down.
  void dispose() {
    final mode = _recordingMode;
    _abortRecording();
    if (mode == 'omarchy' && _testFixture() == null) {
      final bin = _which('omarchy-dictation');
      if (bin != null) {
        try {
          Process.start(bin, const ['stop'], environment: identity.environment);
        } catch (_) {}
      }
    }
  }

  Map<String, dynamic> snapshot([Map<String, dynamic> params = const {}]) {
    if (params.isNotEmpty) {
      throw const FormatException('Unexpected parameters');
    }
    final saved = settings.load();
    final enabled = settings.value(saved, 'dictation') == true;
    final engine = settings.value(saved, 'dictation_engine') as String;
    final whisperModelPref =
        settings.value(saved, 'dictation_whisper_model') as String;
    final fixture = _testFixture();

    final omarchy = _scanOmarchy(fixture);
    final whisper = _scanWhisper(saved, whisperModelPref, fixture);
    final local = _scanLocal(whisper, fixture);
    final online = _scanOnline(fixture);

    var active = '';
    if (engine == 'auto') {
      if (omarchy['ready'] == true) {
        active = 'omarchy';
      } else if (whisper['ready'] == true) {
        active = 'whisper';
      } else if (local['ready'] == true) {
        active = 'local';
      } else if (online['ready'] == true) {
        active = 'online';
      }
    } else {
      final chosen = switch (engine) {
        'omarchy' => omarchy,
        'whisper' => whisper,
        'local' => local,
        'online' => online,
        _ => const <String, dynamic>{},
      };
      if (chosen['ready'] == true) active = engine;
    }

    final activeLabel = switch (active) {
      'omarchy' => omarchy['label'] as String? ?? 'Omarchy',
      'whisper' => whisper['label'] as String? ?? 'Local Whisper',
      'local' => local['label'] as String? ?? 'Local LLM',
      'online' => online['label'] as String? ?? 'Online provider',
      _ => '',
    };
    final configured =
        omarchy['ready'] == true ||
        whisper['ready'] == true ||
        local['ready'] == true ||
        online['ready'] == true;
    final showCost = active == 'online' || engine == 'online';
    final costHint = showCost ? (online['cost_hint'] as String? ?? '') : '';

    return {
      'enabled': enabled,
      'engine': engine,
      'whisper_model': whisper['active_model'] as String? ?? whisperModelPref,
      'active': active,
      'active_label': activeLabel,
      'ready': active.isNotEmpty,
      'configured': configured,
      'recording': _recordingId != null,
      'transcribing': _transcribing,
      'cost_hint': costHint,
      'omarchy': omarchy,
      'whisper': whisper,
      'local': local,
      'online': online,
    };
  }

  Map<String, dynamic> _scanOmarchy(Map<String, dynamic>? fixture) {
    if (fixture != null && fixture['omarchy'] is Map) {
      final m = Map<String, dynamic>.from(fixture['omarchy'] as Map);
      final defaultTool = m['default_tool'] as String? ?? '';
      final voxtype = m['voxtype_installed'] == true;
      final superwhisper = m['superwhisper_configured'] == true;
      final monologue = m['monologue_installed'] == true;
      final ready = m.containsKey('ready')
          ? m['ready'] == true
          : ((defaultTool == 'voxtype' && voxtype) ||
                (defaultTool == 'superwhisper' && superwhisper));
      return {
        'supported': m['supported'] == true,
        'default_tool': defaultTool,
        'omarchy_dictation': m['omarchy_dictation'] ?? ready,
        'voxtype_installed': voxtype,
        'superwhisper_configured': superwhisper,
        'monologue_installed': monologue,
        'ready': ready,
        'configured': ready,
        'label':
            m['label'] as String? ??
            (defaultTool == 'superwhisper' && superwhisper
                ? 'Omarchy · Superwhisper'
                : defaultTool == 'voxtype' && voxtype
                ? 'Omarchy · Voxtype'
                : 'Omarchy dictation'),
      };
    }
    final supported = desktop.name == 'omarchy';
    if (!supported) {
      return {
        'supported': false,
        'default_tool': '',
        'omarchy_dictation': false,
        'voxtype_installed': false,
        'superwhisper_configured': false,
        'monologue_installed': false,
        'ready': false,
        'configured': false,
        'label': 'Omarchy dictation',
      };
    }
    final xdgConfig = identity.environment['XDG_CONFIG_HOME'];
    final configHome = (xdgConfig != null && xdgConfig.isNotEmpty)
        ? xdgConfig
        : p.join(identity.home, '.config');
    final defaultFile = p.join(configHome, 'omarchy', 'defaults', 'dictation');
    final rawDefault = (reads.files.text(defaultFile, limit: 256) ?? '')
        .split('\n')
        .first
        .trim();
    final defaultTool =
        (rawDefault == 'voxtype' || rawDefault == 'superwhisper')
        ? rawDefault
        : '';
    final hasScript = _which('omarchy-dictation') != null;
    final voxtype =
        _which('voxtype') != null &&
        _which('omarchy-dictation-voxtype') != null;
    final superwhisper =
        _which('superwhisper') != null &&
        _which('omarchy-dictation-superwhisper') != null &&
        File(p.join(configHome, 'superwhisper', 'settings.env')).existsSync();
    final monologue = _which('monologue') != null;
    // Ready only when omarchy-default-dictation names an installed backend.
    // Monologue is a companion recorder, not a dictation backend.
    final ready =
        hasScript &&
        ((defaultTool == 'voxtype' && voxtype) ||
            (defaultTool == 'superwhisper' && superwhisper));
    final toolLabel = defaultTool == 'superwhisper' && superwhisper
        ? 'Omarchy · Superwhisper'
        : defaultTool == 'voxtype' && voxtype
        ? 'Omarchy · Voxtype'
        : 'Omarchy dictation';
    return {
      'supported': true,
      'default_tool': defaultTool,
      'omarchy_dictation': hasScript,
      'voxtype_installed': voxtype || _which('voxtype') != null,
      'superwhisper_configured': superwhisper,
      'monologue_installed': monologue,
      'ready': ready,
      'configured': ready,
      'label': toolLabel,
    };
  }

  List<String>? _whisperInstallCmd() {
    if (_which('omarchy-pkg-aur-add') != null) {
      return ['omarchy-pkg-aur-add', 'whisper.cpp'];
    }
    if (_which('yay') != null) {
      return ['yay', '-S', '--needed', 'whisper.cpp'];
    }
    if (_which('paru') != null) {
      return ['paru', '-S', '--needed', 'whisper.cpp'];
    }
    if (_which('brew') != null) {
      return ['brew', 'install', 'whisper-cpp'];
    }
    return null;
  }

  List<String>? _whisperUpdateCmd() {
    if (_which('yay') != null) {
      return ['yay', '-S', 'whisper.cpp'];
    }
    if (_which('paru') != null) {
      return ['paru', '-S', 'whisper.cpp'];
    }
    if (_which('omarchy-pkg-aur-add') != null) {
      return ['omarchy-pkg-aur-add', 'whisper.cpp'];
    }
    if (_which('brew') != null) {
      return ['brew', 'upgrade', 'whisper-cpp'];
    }
    return null;
  }

  List<String>? _whisperRemoveCmd() {
    if (_which('omarchy-pkg-drop') != null) {
      return ['omarchy-pkg-drop', 'whisper.cpp'];
    }
    if (_which('pacman') != null) {
      return ['sudo', 'pacman', '-Rns', 'whisper.cpp'];
    }
    if (_which('brew') != null) {
      return ['brew', 'uninstall', 'whisper-cpp'];
    }
    return null;
  }

  (String, String) _pickActiveWhisperModel(
    List<Map<String, dynamic>> models,
    String preferred,
  ) {
    if (models.isEmpty) return ('', '');
    if (preferred.isNotEmpty) {
      final match = models.where((m) => m['name'] == preferred).firstOrNull;
      if (match != null) {
        return ('${match['name'] ?? ''}', '${match['path'] ?? ''}');
      }
    }
    // Prefer higher-accuracy starter models when several are installed and none
    // was explicitly chosen yet.
    for (final file in const [
      'ggml-large-v3-turbo-q5_0.bin',
      'ggml-small.bin',
      'ggml-base.bin',
    ]) {
      final match = models.where((m) => m['name'] == file).firstOrNull;
      if (match != null) {
        return ('${match['name'] ?? ''}', '${match['path'] ?? ''}');
      }
    }
    return ('${models.first['name'] ?? ''}', '${models.first['path'] ?? ''}');
  }

  Map<String, dynamic> _scanWhisper(
    Map saved,
    String preferredModel,
    Map<String, dynamic>? fixture,
  ) {
    if (fixture != null && fixture['whisper'] is Map) {
      final m = Map<String, dynamic>.from(fixture['whisper'] as Map);
      final models = (m['models'] is List ? m['models'] as List : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final picked = _pickActiveWhisperModel(
        models,
        preferredModel.isNotEmpty
            ? preferredModel
            : (m['active_model'] as String? ?? ''),
      );
      final activeModel = picked.$1.isNotEmpty
          ? picked.$1
          : (m['active_model'] as String? ?? '');
      final activeModelPath = picked.$2.isNotEmpty
          ? picked.$2
          : (m['active_model_path'] as String? ?? '');
      final ready =
          m['ready'] == true ||
          (m['program_installed'] == true && models.isNotEmpty);
      return {
        'program_installed': m['program_installed'] == true,
        'can_install_program': m['can_install_program'] as bool? ?? true,
        'binary': m['binary'] as String? ?? '',
        'recorder_installed': m['recorder_installed'] ?? true,
        'models': models,
        'active_model': activeModel,
        'active_model_path': activeModelPath,
        'catalog': whisperStarterModels,
        'ready': ready,
        'label': ready && activeModel.isNotEmpty
            ? 'Local Whisper · ${activeModel.replaceAll(RegExp(r'\.(bin|gguf)$'), '')}'
            : 'Local Whisper',
      };
    }
    String? binary =
        _which('whisper-cli') ?? _which('whisper-cpp') ?? _which('whisper');
    if (binary == null) {
      for (final candidate in [
        p.join(identity.home, '.local', 'bin', 'whisper-cli'),
        p.join(
          identity.dataDir,
          'programs',
          'llamacpp',
          'current',
          'whisper-cli',
        ),
      ]) {
        if (File(candidate).existsSync()) {
          binary = candidate;
          break;
        }
      }
    }
    final recorder = _recorderBinary() != null;
    final dirs = <String>{
      _managedWhisperDir,
      p.join(identity.home, '.local', 'share', 'voxtype', 'models'),
      p.join(identity.home, '.cache', 'whisper'),
      if (saved['models_root'] is String &&
          (saved['models_root'] as String).isNotEmpty)
        reads.files.expand(saved['models_root'] as String),
      for (final f
          in (saved['model_folders'] is List
              ? saved['model_folders'] as List
              : const []))
        if (f is String && f.isNotEmpty) reads.files.expand(f),
    };
    final models = <Map<String, dynamic>>[];
    final seenPaths = <String>{};
    for (final dirPath in dirs) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (name.endsWith('.part') ||
            !isWhisperModelFile(name) ||
            !seenPaths.add(entry.path)) {
          continue;
        }
        models.add({
          'name': name,
          'path': entry.path,
          'managed': p.equals(dirPath, _managedWhisperDir),
        });
      }
    }
    models.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    final (activeModel, activeModelPath) = _pickActiveWhisperModel(
      models,
      preferredModel,
    );
    final ready = binary != null && recorder && activeModel.isNotEmpty;
    return {
      'program_installed': binary != null,
      'can_install_program': _whisperInstallCmd() != null,
      'binary': binary ?? '',
      'recorder_installed': recorder,
      'models': models,
      'active_model': activeModel,
      'active_model_path': activeModelPath,
      'catalog': whisperStarterModels,
      'ready': ready,
      'label': ready
          ? 'Local Whisper · ${activeModel.replaceAll(RegExp(r'\.(bin|gguf)$'), '')}'
          : 'Local Whisper',
    };
  }

  Map<String, dynamic> _scanLocal(
    Map<String, dynamic> whisper,
    Map<String, dynamic>? fixture,
  ) {
    if (fixture != null && fixture['local'] is Map) {
      final m = Map<String, dynamic>.from(fixture['local'] as Map);
      final models = (m['models'] is List ? m['models'] as List : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final ready = m['ready'] == true;
      return {
        'runtimes': (m['runtimes'] is List ? m['runtimes'] as List : const [])
            .whereType<String>()
            .toList(),
        'models': models,
        'ready': ready,
        'configured': m['configured'] == true || models.isNotEmpty || ready,
        'label':
            m['label'] as String? ??
            (models.isNotEmpty
                ? '${models.first['runtime_name']} · ${models.first['model']}'
                : 'Local LLM'),
      };
    }
    final runtimes = <String>[];
    final models = <Map<String, dynamic>>[];
    for (final rt in reads.inventory.providers.scan()) {
      if (!rt.installed) continue;
      runtimes.add(rt.name);
      for (final model in rt.models) {
        if (voiceRe.hasMatch(model)) {
          models.add({
            'runtime': rt.key,
            'runtime_name': rt.name,
            'model': model,
            'running': rt.running,
            'address': rt.address,
          });
        }
      }
    }
    final recorder = _recorderBinary() != null;
    final ready =
        recorder &&
        models.isNotEmpty &&
        (models.any(
              (m) =>
                  m['running'] == true && (m['address'] as String).isNotEmpty,
            ) ||
            whisper['program_installed'] == true);
    final label = models.isNotEmpty
        ? '${models.first['runtime_name']} · ${models.first['model']}'
        : 'Local LLM';
    return {
      'runtimes': runtimes,
      'models': models,
      'ready': ready,
      'configured': models.isNotEmpty,
      'label': label,
    };
  }

  String _onlineCostHint(String provider) => i18n
      .text(
        'Online dictation sends audio to {0} and uses API credit. Local Whisper or Omarchy dictation is free and stays on this PC.',
      )
      .replaceAll('{0}', provider.isNotEmpty ? provider : 'an online provider');

  Map<String, dynamic> _scanOnline(Map<String, dynamic>? fixture) {
    if (fixture != null && fixture['online'] is Map) {
      final m = Map<String, dynamic>.from(fixture['online'] as Map);
      final provider = m['provider'] as String? ?? '';
      final ready = m.containsKey('ready')
          ? m['ready'] == true
          : provider.isNotEmpty;
      final hint = m['cost_hint'] as String? ?? _onlineCostHint(provider);
      return {
        'provider': provider,
        'ready': ready,
        'cost_hint': hint,
        'label': ready && provider.isNotEmpty
            ? 'Online · $provider'
            : 'Online provider',
      };
    }
    final found = _findOnlineKey();
    final provider = found.$1;
    final ready = provider.isNotEmpty && _recorderBinary() != null;
    final hint = _onlineCostHint(provider);
    return {
      'provider': provider,
      'ready': ready,
      'cost_hint': hint,
      'label': ready ? 'Online · $provider' : 'Online provider',
    };
  }

  /// Returns `(providerName, apiKey, endpointUrl, modelName)` without ever
  /// exposing `apiKey` in snapshots or errors. Reads only environment variables
  /// or `.env` files (never `auth.json` or `.credentials.json`).
  (String, String, String, String) _findOnlineKey() {
    final env = identity.environment;
    final openAiEnv = (env['OPENAI_API_KEY'] ?? '').trim();
    if (openAiEnv.isNotEmpty) {
      return (
        'OpenAI',
        openAiEnv,
        'https://api.openai.com/v1/audio/transcriptions',
        'whisper-1',
      );
    }
    final groqEnv = (env['GROQ_API_KEY'] ?? '').trim();
    if (groqEnv.isNotEmpty) {
      return (
        'Groq',
        groqEnv,
        'https://api.groq.com/openai/v1/audio/transcriptions',
        'whisper-large-v3-turbo',
      );
    }
    final codexEnv =
        reads.files.text(p.join(identity.home, '.codex', '.env')) ?? '';
    for (final raw in codexEnv.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('OPENAI_API_KEY=')) {
        final value = line
            .substring('OPENAI_API_KEY='.length)
            .trim()
            .replaceAll(RegExp('^["\']|["\']\$'), '');
        if (value.isNotEmpty) {
          return (
            'OpenAI',
            value,
            'https://api.openai.com/v1/audio/transcriptions',
            'whisper-1',
          );
        }
      }
    }
    return ('', '', '', '');
  }

  String? _recorderBinary() =>
      _which('pw-record') ?? _which('arecord') ?? _which('ffmpeg');

  void _validateStartParams(Map<String, dynamic> params) {
    if (params.isNotEmpty) {
      throw const FormatException('Unexpected parameters');
    }
  }

  void _validateStopParams(Map<String, dynamic> params) {
    if (params.keys.any((k) => k != 'recording' && k != 'cancel') ||
        (params.containsKey('recording') &&
            params['recording'] != null &&
            params['recording'] is! String) ||
        (params.containsKey('cancel') && params['cancel'] is! bool)) {
      throw const FormatException('Invalid stop parameters');
    }
  }

  Map<String, dynamic> _prepareStart() {
    final snap = snapshot();
    if (snap['enabled'] != true) {
      throw ServiceError(
        'action_refused',
        i18n.text('Dictation is turned off in Settings.'),
      );
    }
    final active = snap['active'] as String? ?? '';
    if (active.isEmpty) {
      throw ServiceError(
        'action_refused',
        i18n.text('Dictation is not set up yet.'),
      );
    }
    return snap;
  }

  /// Synchronous start used by contract probe and fixture tests.
  Map<String, dynamic> start([Map<String, dynamic> params = const {}]) {
    _validateStartParams(params);
    final snap = _prepareStart();
    final active = snap['active'] as String;
    _abortRecording();
    final id = 'rec-${DateTime.now().microsecondsSinceEpoch}';
    if (_testFixture() != null) {
      _recordingId = id;
      _activeEngine = active;
      _recordingMode = active == 'omarchy' ? 'omarchy' : 'wav';
      return {'recording': id, 'engine': active, 'mode': _recordingMode!};
    }
    throw ServiceError(
      'action_refused',
      i18n.text('Dictation requires the async service handler.'),
    );
  }

  /// Asynchronous start used by the live core isolate and async tests.
  Future<Map<String, dynamic>> startAsync([
    Map<String, dynamic> params = const {},
  ]) async {
    _validateStartParams(params);
    final snap = _prepareStart();
    final active = snap['active'] as String;
    _abortRecording();

    final id = 'rec-${DateTime.now().microsecondsSinceEpoch}';
    if (_testFixture() != null) {
      _recordingId = id;
      _activeEngine = active;
      _recordingMode = active == 'omarchy' ? 'omarchy' : 'wav';
      return {'recording': id, 'engine': active, 'mode': _recordingMode!};
    }

    if (active == 'omarchy') {
      final bin = _which('omarchy-dictation');
      if (bin == null) {
        throw ServiceError(
          'action_refused',
          i18n.text('Dictation is not set up yet.'),
        );
      }
      final res = await _runProcess(bin, const ['start']);
      if (res.$1 != 0) {
        final detail = res.$3.trim();
        throw ServiceError(
          'action_refused',
          detail.isNotEmpty
              ? detail
              : i18n.text('Could not start Omarchy dictation.'),
        );
      }
      _recordingId = id;
      _activeEngine = 'omarchy';
      _recordingMode = 'omarchy';
      return {'recording': id, 'engine': 'omarchy', 'mode': 'omarchy'};
    }

    final recorder = _recorderBinary();
    if (recorder == null) {
      throw ServiceError(
        'action_refused',
        i18n.text(
          'No audio recorder (pw-record, arecord, or ffmpeg) was found on this PC.',
        ),
      );
    }
    final dir = Directory.systemTemp.createTempSync('maprisma-dictation-');
    try {
      settings.posix.chmodPath(dir.path, 0x1c0);
    } catch (_) {}
    final wavPath = p.join(dir.path, 'capture.wav');
    final name = p.basename(recorder);
    final args = switch (name) {
      'pw-record' => [
        '--rate',
        '16000',
        '--channels',
        '1',
        '--format',
        's16',
        wavPath,
      ],
      'arecord' => [
        '-q',
        '-f',
        'S16_LE',
        '-r',
        '16000',
        '-c',
        '1',
        '-t',
        'wav',
        wavPath,
      ],
      _ => [
        '-nostdin',
        '-loglevel',
        'quiet',
        '-f',
        'pulse',
        '-i',
        'default',
        '-ac',
        '1',
        '-ar',
        '16000',
        '-c:a',
        'pcm_s16le',
        '-y',
        wavPath,
      ],
    };

    // Start the recorder under a pipe-bound watchdog: when stdin closes (either
    // on stop/cancel/dispose or automatically by the kernel if Maprisma exits),
    // `read -r _` returns EOF and the shell immediately stops the recorder.
    Process proc;
    int? pid;
    try {
      proc = await Process.start('/bin/sh', [
        '-c',
        r'echo "$$"; exec 3<&0; ( p=$$; read -r _ <&3 || true; kill -INT "$p" 2>/dev/null; sleep 0.05; kill -TERM "$p" 2>/dev/null ) >/dev/null 2>&1 & exec "$0" "$@" </dev/null >/dev/null 2>&1 3<&-',
        recorder,
        ...args,
      ], environment: identity.environment);
      proc.stderr.drain<void>();
      final firstLine = await proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 3));
      pid = int.tryParse(firstLine.trim());
    } catch (_) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      throw ServiceError(
        'action_refused',
        i18n.text(
          'No audio recorder (pw-record, arecord, or ffmpeg) was found on this PC.',
        ),
      );
    }
    if (pid == null) {
      proc.kill();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      throw ServiceError(
        'action_refused',
        i18n.text(
          'No audio recorder (pw-record, arecord, or ffmpeg) was found on this PC.',
        ),
      );
    }

    _recordingId = id;
    _activeEngine = active;
    _recordingMode = 'wav';
    _recordingDir = dir;
    _recordingWav = wavPath;
    _recordingPid = pid;
    _recorderProcess = proc;
    return {'recording': id, 'engine': active, 'mode': 'wav'};
  }

  /// Synchronous stop used by contract probe and fixture tests.
  Map<String, dynamic> stop([Map<String, dynamic> params = const {}]) {
    _validateStopParams(params);
    final cancel = params['cancel'] == true;
    if (_recordingId == null) {
      if (cancel) {
        return {
          'text': '',
          'engine': '',
          'mode': 'wav',
          'elapsed_ms': 0,
          'cost_hint': '',
          'typed_by_desktop': false,
        };
      }
      throw ServiceError(
        'action_refused',
        i18n.text('No dictation recording is running.'),
      );
    }
    if (params['recording'] != null && params['recording'] != _recordingId) {
      throw const FormatException('Unknown recording');
    }
    final engine = _activeEngine ?? 'whisper';
    final mode = _recordingMode ?? 'wav';
    final fixture = _testFixture();
    if (cancel) {
      _abortRecording();
      return {
        'text': '',
        'engine': engine,
        'mode': mode,
        'elapsed_ms': 0,
        'cost_hint': '',
        'typed_by_desktop': false,
      };
    }
    if (fixture != null) {
      _abortRecording();
      final snap = snapshot();
      final online = snap['online'] as Map<String, dynamic>? ?? const {};
      final text = mode == 'omarchy' && !fixture.containsKey('text')
          ? ''
          : (fixture['text'] as String? ?? 'Hello from test dictation.');
      return {
        'text': text,
        'engine': engine,
        'mode': mode,
        'elapsed_ms': mode == 'omarchy' ? 0 : 120,
        'cost_hint': engine == 'online'
            ? (online['cost_hint'] as String? ?? '')
            : '',
        'typed_by_desktop': mode == 'omarchy' && text.isEmpty,
      };
    }
    throw ServiceError(
      'action_refused',
      i18n.text('Dictation requires the async service handler.'),
    );
  }

  /// Asynchronous stop + transcription without blocking the core isolate.
  Future<Map<String, dynamic>> stopAsync([
    Map<String, dynamic> params = const {},
  ]) async {
    _validateStopParams(params);
    final cancel = params['cancel'] == true;
    if (_recordingId == null) {
      if (cancel) {
        return {
          'text': '',
          'engine': '',
          'mode': 'wav',
          'elapsed_ms': 0,
          'cost_hint': '',
          'typed_by_desktop': false,
        };
      }
      throw ServiceError(
        'action_refused',
        i18n.text('No dictation recording is running.'),
      );
    }
    if (params['recording'] != null && params['recording'] != _recordingId) {
      throw const FormatException('Unknown recording');
    }
    final engine = _activeEngine ?? 'whisper';
    final mode = _recordingMode ?? 'wav';
    final fixture = _testFixture();

    if (cancel) {
      _abortRecording();
      if (mode == 'omarchy' && fixture == null) {
        final bin = _which('omarchy-dictation');
        if (bin != null) {
          await _runProcess(bin, const ['stop']);
        }
      }
      return {
        'text': '',
        'engine': engine,
        'mode': mode,
        'elapsed_ms': 0,
        'cost_hint': '',
        'typed_by_desktop': false,
      };
    }

    if (fixture != null) {
      _abortRecording();
      final snap = snapshot();
      final online = snap['online'] as Map<String, dynamic>? ?? const {};
      final text = mode == 'omarchy' && !fixture.containsKey('text')
          ? ''
          : (fixture['text'] as String? ?? 'Hello from test dictation.');
      return {
        'text': text,
        'engine': engine,
        'mode': mode,
        'elapsed_ms': mode == 'omarchy' ? 0 : 120,
        'cost_hint': engine == 'online'
            ? (online['cost_hint'] as String? ?? '')
            : '',
        'typed_by_desktop': mode == 'omarchy' && text.isEmpty,
      };
    }

    if (mode == 'omarchy') {
      _abortRecording();
      final bin = _which('omarchy-dictation');
      if (bin != null) {
        await _runProcess(bin, const ['stop']);
      }
      return {
        'text': '',
        'engine': 'omarchy',
        'mode': 'omarchy',
        'elapsed_ms': 0,
        'cost_hint': '',
        'typed_by_desktop': true,
      };
    }

    final wavPath = _recordingWav;
    final pid = _recordingPid;
    final proc = _recorderProcess;
    _recordingId = null;
    _recordingMode = null;
    _activeEngine = null;
    _recordingPid = null;
    _recorderProcess = null;
    _transcribing = true;

    try {
      // Wait briefly if the WAV header is still being created, then close the
      // watchdog pipe so `/bin/sh` sends SIGINT to pw-record and waits for it.
      if (wavPath != null) {
        for (var i = 0; i < 8; i++) {
          final f = File(wavPath);
          if (f.existsSync()) {
            final len = f.lengthSync();
            if (len > 0 && len != 44) break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      if (proc != null) {
        try {
          proc.stdin.writeln();
          await proc.stdin.close();
        } catch (_) {}
        try {
          await proc.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          if (pid != null) {
            Process.killPid(pid, ProcessSignal.sigkill);
          }
          proc.kill(ProcessSignal.sigkill);
        }
      } else if (pid != null) {
        Process.killPid(pid, ProcessSignal.sigint);
      }

      final wavLen = wavPath != null && File(wavPath).existsSync()
          ? File(wavPath).lengthSync()
          : 0;
      if (wavPath == null || wavLen == 0 || wavLen == 44) {
        throw ServiceError(
          'action_refused',
          i18n.text(
            'No speech was recorded. Check your microphone and try again.',
          ),
        );
      }

      final snap = snapshot();
      final transcribeWatch = Stopwatch()..start();
      final text = await _transcribeWav(wavPath, engine, snap);
      transcribeWatch.stop();
      final online = snap['online'] as Map<String, dynamic>? ?? const {};
      return {
        'text': text,
        'engine': engine,
        'mode': 'wav',
        'elapsed_ms': transcribeWatch.elapsedMilliseconds,
        'cost_hint': engine == 'online'
            ? (online['cost_hint'] as String? ?? '')
            : '',
        'typed_by_desktop': false,
      };
    } finally {
      _transcribing = false;
      _abortRecording();
    }
  }

  Future<(int, String, String)> _runProcess(
    String executable,
    List<String> args, {
    String? stdinText,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    Process process;
    try {
      process = await Process.start(
        executable,
        args,
        environment: identity.environment,
      );
    } on ProcessException {
      return (127, '', '');
    }
    if (stdinText != null) {
      try {
        process.stdin.add(utf8.encode(stdinText));
        await process.stdin.close();
      } catch (_) {}
    } else {
      try {
        await process.stdin.close();
      } catch (_) {}
    }
    final outFuture = process.stdout.transform(utf8.decoder).join();
    final errFuture = process.stderr.transform(utf8.decoder).join();
    int code;
    try {
      code = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return (124, '', 'Timed out');
    }
    return (code, await outFuture, await errFuture);
  }

  Future<String> _transcribeWav(
    String wavPath,
    String engine,
    Map<String, dynamic> snap,
  ) async {
    if (engine == 'whisper') {
      final whisper = snap['whisper'] as Map<String, dynamic>? ?? const {};
      final bin = whisper['binary'] as String? ?? '';
      final modelPath = whisper['active_model_path'] as String? ?? '';
      if (bin.isEmpty || modelPath.isEmpty) {
        throw ServiceError(
          'action_refused',
          i18n.text('Whisper is not set up completely yet.'),
        );
      }
      return _runWhisperCli(bin, modelPath, wavPath);
    }
    if (engine == 'local') {
      final local = snap['local'] as Map<String, dynamic>? ?? const {};
      final models = (local['models'] is List ? local['models'] as List : [])
          .whereType<Map>();
      for (final m in models) {
        final addr = (m['address'] as String? ?? '').trim();
        if (m['running'] == true && addr.isNotEmpty) {
          final uri = Uri.tryParse(
            addr.startsWith('http') ? addr : 'http://$addr',
          );
          if (uri != null &&
              (uri.host == '127.0.0.1' ||
                  uri.host == 'localhost' ||
                  uri.host == '::1')) {
            final endpoint = uri
                .replace(path: '/v1/audio/transcriptions')
                .toString();
            final modelName = m['model'] as String? ?? 'whisper-1';
            final res = await _runProcess('curl', [
              '-sS',
              '--max-time',
              '60',
              '-X',
              'POST',
              endpoint,
              '-F',
              'file=@$wavPath',
              '-F',
              'model=$modelName',
            ]);
            if (res.$1 == 0) {
              final parsed = _extractJsonText(res.$2);
              if (parsed.isNotEmpty) return parsed;
            }
          }
        }
      }
      final whisper = snap['whisper'] as Map<String, dynamic>? ?? const {};
      final bin = whisper['binary'] as String? ?? '';
      final modelPath = whisper['active_model_path'] as String? ?? '';
      if (bin.isNotEmpty && modelPath.isNotEmpty) {
        return _runWhisperCli(bin, modelPath, wavPath);
      }
      throw ServiceError(
        'action_refused',
        i18n.text(
          'No speech model (such as Whisper) was found in your local LLMs yet.',
        ),
      );
    }
    if (engine == 'online') {
      final (_, key, endpoint, model) = _findOnlineKey();
      if (key.isEmpty || endpoint.isEmpty) {
        throw ServiceError(
          'action_refused',
          i18n.text(
            'No online transcription API key (OPENAI_API_KEY or GROQ_API_KEY) was found.',
          ),
        );
      }
      final res = await _runProcess('curl', [
        '-sS',
        '--max-time',
        '60',
        '-K',
        '-',
        '-X',
        'POST',
        endpoint,
        '-F',
        'file=@$wavPath',
        '-F',
        'model=$model',
      ], stdinText: 'header = "Authorization: Bearer $key"\n');
      if (res.$1 != 0) {
        throw ServiceError(
          'action_refused',
          i18n.text('Online transcription failed.'),
        );
      }
      return _extractJsonText(res.$2);
    }
    throw ServiceError(
      'action_refused',
      i18n.text('Dictation is not set up yet.'),
    );
  }

  Future<String> _runWhisperCli(
    String bin,
    String modelPath,
    String wavPath,
  ) async {
    final res = await _runProcess(bin, [
      '-m',
      modelPath,
      '-f',
      wavPath,
      '--no-timestamps',
      '-nt',
      '-l',
      'auto',
    ]);
    if (res.$1 != 0) {
      throw ServiceError(
        'action_refused',
        i18n.text('Local Whisper transcription failed.'),
      );
    }
    final lines = res.$2
        .split('\n')
        .map((l) => l.trim())
        .where(
          (l) =>
              l.isNotEmpty &&
              !l.startsWith('[') &&
              !l.toUpperCase().contains('BLANK_AUDIO'),
        )
        .toList();
    return lines.join(' ').trim();
  }

  String _extractJsonText(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['text'] is String) {
        return (decoded['text'] as String).trim();
      }
    } catch (_) {}
    return raw.trim();
  }

  void _abortRecording() {
    final pid = _recordingPid;
    final proc = _recorderProcess;
    final dir = _recordingDir;
    _recordingId = null;
    _recordingMode = null;
    _activeEngine = null;
    _recordingPid = null;
    _recorderProcess = null;
    _recordingWav = null;
    _recordingDir = null;
    if (proc != null) {
      try {
        proc.stdin.close();
      } catch (_) {}
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
    if (pid != null) {
      try {
        Process.killPid(pid, ProcessSignal.sigint);
      } catch (_) {}
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {}
    }
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  Map<String, dynamic> run(Map<String, dynamic> params) {
    if (params.keys.any((k) => k != 'action' && k != 'target') ||
        params['action'] is! String ||
        (params.containsKey('target') && params['target'] is! String)) {
      throw const FormatException('Invalid dictation action');
    }
    final action = params['action'] as String;
    final target = (params['target'] as String? ?? '').trim();
    const validActions = {
      'install_voxtype',
      'install_superwhisper',
      'install_monologue',
      'update_omarchy',
      'remove_voxtype',
      'remove_superwhisper',
      'remove_monologue',
      'voxtype_model',
      'voxtype_config',
      'use_voxtype',
      'use_superwhisper',
      'open_monologue',
      'install_whisper',
      'update_whisper',
      'remove_whisper',
      'download_whisper_model',
      'remove_whisper_model',
      'select_whisper_model',
    };
    if (!validActions.contains(action)) {
      throw const FormatException('Unknown dictation action');
    }
    final prompt = i18n.text('Press Enter to close');

    if (action == 'select_whisper_model') {
      if (target.isEmpty ||
          target.contains('/') ||
          target.contains('\\') ||
          target.contains('..') ||
          !isWhisperModelFile(target)) {
        throw const FormatException('Invalid Whisper model name');
      }
      settings.saveOwn({'dictation_whisper_model': target});
      if (_testFixture() != null) {
        testActions.add({'action': action, 'target': target});
      }
      return {'ok': true};
    }

    if (action == 'download_whisper_model') {
      final entry = whisperStarterModels
          .where((m) => m['id'] == target || m['file'] == target)
          .toList();
      if (entry.isEmpty) {
        throw const FormatException('Unknown Whisper model');
      }
      final model = entry.first;
      final fileName = model['file'] as String;
      settings.saveOwn({'dictation_whisper_model': fileName});
      if (_testFixture() != null) {
        testActions.add({'action': action, 'target': target});
        return {'ok': true};
      }
      Directory(_managedWhisperDir).createSync(recursive: true);
      final dest = p.join(_managedWhisperDir, fileName);
      final part = '$dest.part';
      final url = model['url'] as String;
      final ok = desktop.runStepsInTerminal([
        ['curl', '-fL', '--progress-bar', '-o', part, url],
        ['mv', '-f', part, dest],
      ], prompt);
      if (!ok) {
        throw ServiceError(
          'action_refused',
          i18n.text('No terminal was found to run this setup step.'),
        );
      }
      return {'ok': true};
    }

    if (action == 'remove_whisper_model') {
      if (target.isEmpty ||
          target.contains('/') ||
          target.contains('\\') ||
          target.contains('..') ||
          !RegExp(r'^[A-Za-z0-9._-]+\.(bin|gguf)$').hasMatch(target)) {
        throw const FormatException('Invalid Whisper model name');
      }
      final saved = settings.load();
      if (saved['dictation_whisper_model'] == target) {
        settings.saveOwn({'dictation_whisper_model': ''});
      }
      if (_testFixture() != null) {
        testActions.add({'action': action, 'target': target});
        return {'ok': true};
      }
      for (final candidate in [
        File(p.join(_managedWhisperDir, target)),
        File(p.join(_managedWhisperDir, '$target.part')),
      ]) {
        if (FileSystemEntity.typeSync(candidate.path, followLinks: false) ==
            FileSystemEntityType.file) {
          candidate.deleteSync();
        }
      }
      return {'ok': true};
    }

    if (action == 'update_omarchy') {
      final omarchy = _scanOmarchy(_testFixture());
      final pkgs = <String>[
        if (omarchy['voxtype_installed'] == true) 'voxtype-bin',
        if (omarchy['superwhisper_configured'] == true ||
            _which('superwhisper') != null)
          'superwhisper-bin',
        if (omarchy['monologue_installed'] == true) 'monologue',
      ];
      if (pkgs.isEmpty) {
        throw ServiceError(
          'action_refused',
          i18n.text('Dictation is not set up yet.'),
        );
      }
      if (_testFixture() != null) {
        testActions.add({'action': action, 'packages': pkgs});
        return {'ok': true};
      }
      final ok = desktop.runStepsInTerminal([
        ['sudo', 'pacman', '-S', ...pkgs],
      ], prompt);
      if (!ok) {
        throw ServiceError(
          'action_refused',
          i18n.text('No terminal was found to run this setup step.'),
        );
      }
      return {'ok': true};
    }

    if (_testFixture() != null) {
      testActions.add({
        'action': action,
        if (target.isNotEmpty) 'target': target,
      });
      return {'ok': true};
    }

    final env = identity.environment;
    if (action == 'open_monologue') {
      final bin = _which('monologue');
      if (bin == null) {
        throw ServiceError(
          'action_refused',
          i18n.text('Monologue is not installed.'),
        );
      }
      Process.start(
        bin,
        const [],
        environment: env,
        mode: ProcessStartMode.detached,
      );
      return {'ok': true};
    }

    List<List<String>> steps;
    switch (action) {
      case 'install_voxtype':
        steps = [
          ['omarchy-install-dictation-voxtype'],
        ];
      case 'install_superwhisper':
        steps = [
          ['omarchy-install-dictation-superwhisper'],
        ];
      case 'install_monologue':
        steps = [
          _which('omarchy-pkg-add') != null
              ? ['omarchy-pkg-add', 'monologue']
              : ['sudo', 'pacman', '-S', '--needed', 'monologue'],
        ];
      case 'remove_voxtype':
        steps = [
          ['omarchy-remove-dictation-voxtype'],
        ];
      case 'remove_superwhisper':
        steps = [
          ['omarchy-remove-dictation-superwhisper'],
        ];
      case 'remove_monologue':
        steps = [
          _which('omarchy-pkg-drop') != null
              ? ['omarchy-pkg-drop', 'monologue']
              : ['sudo', 'pacman', '-Rns', 'monologue'],
        ];
      case 'voxtype_model':
        steps = [
          ['omarchy-voxtype-model'],
        ];
      case 'voxtype_config':
        steps = [
          ['omarchy-voxtype-config'],
        ];
      case 'use_voxtype':
        steps = [
          ['omarchy-dictation-use', 'voxtype'],
        ];
      case 'use_superwhisper':
        steps = [
          ['omarchy-dictation-use', 'superwhisper'],
        ];
      case 'install_whisper':
        final installCmd = _whisperInstallCmd();
        if (installCmd == null) {
          throw ServiceError(
            'action_refused',
            i18n.text(
              'No AUR helper (yay or paru) was found to install whisper.cpp.',
            ),
          );
        }
        steps = [installCmd];
        final model = whisperStarterModels
            .where((m) => m['id'] == (target.isEmpty ? 'base' : target))
            .toList();
        if (model.isNotEmpty) {
          final fileName = model.first['file'] as String;
          settings.saveOwn({'dictation_whisper_model': fileName});
          Directory(_managedWhisperDir).createSync(recursive: true);
          final dest = p.join(_managedWhisperDir, fileName);
          final part = '$dest.part';
          final url = model.first['url'] as String;
          steps.add(['curl', '-fL', '--progress-bar', '-o', part, url]);
          steps.add(['mv', '-f', part, dest]);
        }
      case 'update_whisper':
        final updateCmd = _whisperUpdateCmd();
        if (updateCmd == null) {
          throw ServiceError(
            'action_refused',
            i18n.text(
              'No AUR helper (yay or paru) was found to install whisper.cpp.',
            ),
          );
        }
        steps = [updateCmd];
      case 'remove_whisper':
        final removeCmd = _whisperRemoveCmd();
        if (removeCmd == null) {
          throw ServiceError(
            'action_refused',
            i18n.text(
              'No AUR helper (yay or paru) was found to install whisper.cpp.',
            ),
          );
        }
        steps = [removeCmd];
      default:
        steps = const [];
    }
    final ok = desktop.runStepsInTerminal(steps, prompt);
    if (!ok) {
      throw ServiceError(
        'action_refused',
        i18n.text('No terminal was found to run this setup step.'),
      );
    }
    return {'ok': true};
  }
}
