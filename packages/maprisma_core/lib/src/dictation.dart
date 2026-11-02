import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'desktop.dart';
import 'health_report.dart' show voiceRe;
import 'identity.dart';
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
  Stopwatch? _startedAt;
  Directory? _recordingDir;
  String? _recordingWav;
  int? _recordingPid;
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

  Map<String, dynamic> snapshot([Map<String, dynamic> params = const {}]) {
    if (params.isNotEmpty) {
      throw const FormatException('Unexpected parameters');
    }
    final saved = settings.load();
    final enabled = settings.value(saved, 'dictation') == true;
    final engine = settings.value(saved, 'dictation_engine') as String;
    final fixture = _testFixture();

    final omarchy = _scanOmarchy(fixture);
    final whisper = _scanWhisper(saved, fixture);
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
      'active': active,
      'active_label': activeLabel,
      'ready': active.isNotEmpty,
      'configured': configured,
      'recording': _recordingId != null,
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
      return {
        'supported': m['supported'] == true,
        'default_tool': m['default_tool'] as String? ?? '',
        'omarchy_dictation': m['omarchy_dictation'] == true,
        'voxtype_installed': m['voxtype_installed'] == true,
        'superwhisper_configured': m['superwhisper_configured'] == true,
        'monologue_installed': m['monologue_installed'] == true,
        'ready': m['ready'] == true,
        'configured': m['configured'] == true || m['ready'] == true,
        'label': m['label'] as String? ?? 'Omarchy dictation',
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
    final defaultFile = p.join(
      identity.home,
      '.config',
      'omarchy',
      'defaults',
      'dictation',
    );
    final rawDefault = (reads.files.text(defaultFile, limit: 256) ?? '').trim();
    final defaultTool =
        (rawDefault == 'voxtype' || rawDefault == 'superwhisper')
        ? rawDefault
        : '';
    final hasScript = _which('omarchy-dictation') != null;
    final voxtype = _which('voxtype') != null;
    final superwhisper = File(
      p.join(identity.home, '.config', 'superwhisper', 'settings.env'),
    ).existsSync();
    final monologue = _which('monologue') != null;
    final ready =
        hasScript &&
        ((defaultTool == 'superwhisper' && superwhisper) ||
            (voxtype && (defaultTool == 'voxtype' || defaultTool.isEmpty)));
    final toolLabel = defaultTool == 'superwhisper' && superwhisper
        ? 'Omarchy · Superwhisper'
        : voxtype
        ? 'Omarchy · Voxtype'
        : monologue
        ? 'Omarchy · Monologue'
        : 'Omarchy dictation';
    return {
      'supported': true,
      'default_tool': defaultTool,
      'omarchy_dictation': hasScript,
      'voxtype_installed': voxtype,
      'superwhisper_configured': superwhisper,
      'monologue_installed': monologue,
      'ready': ready,
      'configured': ready || monologue,
      'label': toolLabel,
    };
  }

  Map<String, dynamic> _scanWhisper(Map saved, Map<String, dynamic>? fixture) {
    if (fixture != null && fixture['whisper'] is Map) {
      final m = Map<String, dynamic>.from(fixture['whisper'] as Map);
      final models = (m['models'] is List ? m['models'] as List : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final activeModel =
          m['active_model'] as String? ??
          (models.isNotEmpty ? models.first['name'] as String? ?? '' : '');
      final ready =
          m['ready'] == true ||
          (m['program_installed'] == true && models.isNotEmpty);
      return {
        'program_installed': m['program_installed'] == true,
        'binary': m['binary'] as String? ?? '',
        'recorder_installed': m['recorder_installed'] ?? true,
        'models': models,
        'active_model': activeModel,
        'active_model_path':
            m['active_model_path'] as String? ??
            (models.isNotEmpty ? models.first['path'] as String? ?? '' : ''),
        'catalog': whisperStarterModels,
        'ready': ready,
        'label': ready && activeModel.isNotEmpty
            ? 'Local Whisper · $activeModel'
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
        final lower = name.toLowerCase();
        final isWhisperModel =
            (lower.startsWith('ggml-') && lower.endsWith('.bin')) ||
            (lower.contains('whisper') &&
                (lower.endsWith('.bin') || lower.endsWith('.gguf')));
        if (!isWhisperModel || !seenPaths.add(entry.path)) continue;
        models.add({
          'name': name,
          'path': entry.path,
          'managed': p.equals(dirPath, _managedWhisperDir),
        });
      }
    }
    models.sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
    final activeModel = models.isNotEmpty ? models.first['name'] as String : '';
    final activeModelPath = models.isNotEmpty
        ? models.first['path'] as String
        : '';
    final ready = binary != null && recorder && models.isNotEmpty;
    return {
      'program_installed': binary != null,
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

  Map<String, dynamic> start([Map<String, dynamic> params = const {}]) {
    if (params.isNotEmpty) {
      throw const FormatException('Unexpected parameters');
    }
    final snap = snapshot();
    if (snap['enabled'] != true) {
      throw const FormatException('Dictation is switched off');
    }
    final active = snap['active'] as String? ?? '';
    if (active.isEmpty) {
      throw const FormatException('Dictation is not set up yet');
    }
    _cleanupRecording();

    final id = 'rec-${DateTime.now().microsecondsSinceEpoch}';
    final fixture = _testFixture();
    if (fixture != null) {
      _recordingId = id;
      _activeEngine = active;
      _recordingMode = active == 'omarchy' ? 'omarchy' : 'wav';
      _startedAt = Stopwatch()..start();
      return {'recording': id, 'engine': active, 'mode': _recordingMode!};
    }

    if (active == 'omarchy') {
      final bin = _which('omarchy-dictation');
      if (bin == null) {
        throw const FormatException('Omarchy dictation is not installed');
      }
      final res = Process.runSync(bin, const [
        'start',
      ], environment: identity.environment);
      if (res.exitCode != 0) {
        throw const FormatException('Could not start Omarchy dictation');
      }
      _recordingId = id;
      _activeEngine = 'omarchy';
      _recordingMode = 'omarchy';
      _startedAt = Stopwatch()..start();
      return {'recording': id, 'engine': 'omarchy', 'mode': 'omarchy'};
    }

    final recorder = _recorderBinary();
    if (recorder == null) {
      throw const FormatException('No audio recorder found (pw-record)');
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
    final spawn = Process.runSync('/bin/sh', [
      '-c',
      r'exec "$0" "$@" </dev/null >/dev/null 2>&1 & echo $!',
      recorder,
      ...args,
    ], environment: identity.environment);
    final pid = int.tryParse('${spawn.stdout}'.trim());
    if (spawn.exitCode != 0 || pid == null) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
      throw const FormatException('Could not start audio recorder');
    }
    _recordingId = id;
    _activeEngine = active;
    _recordingMode = 'wav';
    _recordingDir = dir;
    _recordingWav = wavPath;
    _recordingPid = pid;
    _startedAt = Stopwatch()..start();
    return {'recording': id, 'engine': active, 'mode': 'wav'};
  }

  Map<String, dynamic> stop([Map<String, dynamic> params = const {}]) {
    if (params.keys.any((k) => k != 'recording') ||
        (params.containsKey('recording') && params['recording'] is! String)) {
      throw const FormatException('Invalid stop parameters');
    }
    if (_recordingId == null) {
      throw const FormatException('No recording in progress');
    }
    if (params['recording'] != null && params['recording'] != _recordingId) {
      throw const FormatException('Unknown recording');
    }
    final elapsedMs = _startedAt?.elapsedMilliseconds ?? 0;
    final engine = _activeEngine ?? 'whisper';
    final mode = _recordingMode ?? 'wav';
    final fixture = _testFixture();

    if (fixture != null) {
      _recordingId = null;
      _recordingMode = null;
      _activeEngine = null;
      _startedAt = null;
      final snap = snapshot();
      final online = snap['online'] as Map<String, dynamic>? ?? const {};
      return {
        'text': fixture['text'] as String? ?? 'Hello from test dictation.',
        'engine': engine,
        'mode': mode,
        'elapsed_ms': elapsedMs > 0 ? elapsedMs : 350,
        'cost_hint': engine == 'online'
            ? (online['cost_hint'] as String? ?? '')
            : '',
      };
    }

    if (mode == 'omarchy') {
      _recordingId = null;
      _recordingMode = null;
      _activeEngine = null;
      _startedAt = null;
      final bin = _which('omarchy-dictation');
      if (bin != null) {
        Process.runSync(bin, const ['stop'], environment: identity.environment);
      }
      return {
        'text': '',
        'engine': 'omarchy',
        'mode': 'omarchy',
        'elapsed_ms': elapsedMs,
        'cost_hint': '',
      };
    }

    final wavPath = _recordingWav;
    final pid = _recordingPid;
    final dir = _recordingDir;
    try {
      if (pid != null) {
        Process.runSync('/bin/sh', [
          '-c',
          r'for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$2" ] && break; sleep 0.05; done; kill -INT "$1" 2>/dev/null || true; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$1" 2>/dev/null || exit 0; sleep 0.05; done; kill -TERM "$1" 2>/dev/null || true',
          'sh',
          '$pid',
          wavPath ?? '',
        ]);
      }
      if (wavPath == null || !File(wavPath).existsSync()) {
        throw const FormatException('Recorded audio was empty');
      }
      final snap = snapshot();
      final text = _transcribeWav(wavPath, dir?.path ?? '', engine, snap);
      final online = snap['online'] as Map<String, dynamic>? ?? const {};
      return {
        'text': text,
        'engine': engine,
        'mode': 'wav',
        'elapsed_ms': elapsedMs,
        'cost_hint': engine == 'online'
            ? (online['cost_hint'] as String? ?? '')
            : '',
      };
    } finally {
      _cleanupRecording();
    }
  }

  String _transcribeWav(
    String wavPath,
    String dirPath,
    String engine,
    Map<String, dynamic> snap,
  ) {
    if (engine == 'whisper') {
      final whisper = snap['whisper'] as Map<String, dynamic>? ?? const {};
      final bin = whisper['binary'] as String? ?? '';
      final modelPath = whisper['active_model_path'] as String? ?? '';
      if (bin.isEmpty || modelPath.isEmpty) {
        throw const FormatException('Local Whisper is not set up');
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
            final res = Process.runSync('curl', [
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
            ], environment: identity.environment);
            if (res.exitCode == 0) {
              final parsed = _extractJsonText('${res.stdout}');
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
      throw const FormatException('Local speech model did not respond');
    }
    if (engine == 'online') {
      final (_, key, endpoint, model) = _findOnlineKey();
      if (key.isEmpty || endpoint.isEmpty) {
        throw const FormatException('No online transcription key is set up');
      }
      final cfgPath = p.join(dirPath, 'curl.cfg');
      settings.posix.atomicWrite(
        cfgPath,
        utf8.encode('header = "Authorization: Bearer $key"\n'),
      );
      final res = Process.runSync('curl', [
        '-sS',
        '--max-time',
        '60',
        '--config',
        cfgPath,
        '-X',
        'POST',
        endpoint,
        '-F',
        'file=@$wavPath',
        '-F',
        'model=$model',
      ], environment: identity.environment);
      if (res.exitCode != 0) {
        throw const FormatException('Online transcription failed');
      }
      return _extractJsonText('${res.stdout}');
    }
    throw const FormatException('Unknown dictation engine');
  }

  String _runWhisperCli(String bin, String modelPath, String wavPath) {
    final res = Process.runSync(bin, [
      '-m',
      modelPath,
      '-f',
      wavPath,
      '--no-timestamps',
      '-nt',
      '-l',
      'auto',
    ], environment: identity.environment);
    if (res.exitCode != 0) {
      throw const FormatException('Whisper transcription failed');
    }
    final lines = '${res.stdout}'
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

  void _cleanupRecording() {
    final pid = _recordingPid;
    final dir = _recordingDir;
    _recordingId = null;
    _recordingMode = null;
    _activeEngine = null;
    _startedAt = null;
    _recordingPid = null;
    _recordingWav = null;
    _recordingDir = null;
    if (pid != null) {
      try {
        Process.runSync('/bin/sh', [
          '-c',
          r'kill -TERM "$1" 2>/dev/null || true',
          'sh',
          '$pid',
        ]);
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
    };
    if (!validActions.contains(action)) {
      throw const FormatException('Unknown dictation action');
    }
    final prompt = i18n.text('Press Enter to close');
    if (action == 'download_whisper_model') {
      final entry = whisperStarterModels
          .where((m) => m['id'] == target || m['file'] == target)
          .toList();
      if (entry.isEmpty) {
        throw const FormatException('Unknown Whisper model');
      }
      if (_testFixture() != null) {
        testActions.add({'action': action, 'target': target});
        return {'ok': true};
      }
      final model = entry.first;
      Directory(_managedWhisperDir).createSync(recursive: true);
      final dest = p.join(_managedWhisperDir, model['file'] as String);
      final url = model['url'] as String;
      final ok = desktop.runStepsInTerminal([
        ['curl', '-fL', '--progress-bar', '-o', dest, url],
      ], prompt);
      return {'ok': ok};
    }
    if (action == 'remove_whisper_model') {
      if (target.isEmpty ||
          target.contains('/') ||
          target.contains('\\') ||
          target.contains('..') ||
          !RegExp(r'^[A-Za-z0-9._-]+\.(bin|gguf)$').hasMatch(target)) {
        throw const FormatException('Invalid Whisper model name');
      }
      if (_testFixture() != null) {
        testActions.add({'action': action, 'target': target});
        return {'ok': true};
      }
      final file = File(p.join(_managedWhisperDir, target));
      if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.file) {
        file.deleteSync();
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
        throw const FormatException('Monologue is not installed');
      }
      Process.start(
        bin,
        const [],
        environment: env,
        mode: ProcessStartMode.detached,
      );
      return {'ok': true};
    }

    final steps = switch (action) {
      'install_voxtype' => [
        ['omarchy-install-dictation-voxtype'],
      ],
      'install_superwhisper' => [
        ['omarchy-install-dictation-superwhisper'],
      ],
      'install_monologue' => [
        _which('omarchy-pkg-add') != null
            ? ['omarchy-pkg-add', 'monologue']
            : ['sudo', 'pacman', '-S', '--needed', 'monologue'],
      ],
      'update_omarchy' => [
        ['sudo', 'pacman', '-Syu', '--needed', 'voxtype-bin', 'monologue'],
      ],
      'remove_voxtype' => [
        ['omarchy-remove-dictation-voxtype'],
      ],
      'remove_superwhisper' => [
        ['omarchy-remove-dictation-superwhisper'],
      ],
      'remove_monologue' => [
        _which('omarchy-pkg-drop') != null
            ? ['omarchy-pkg-drop', 'monologue']
            : ['sudo', 'pacman', '-Rns', 'monologue'],
      ],
      'voxtype_model' => [
        ['omarchy-voxtype-model'],
      ],
      'voxtype_config' => [
        ['omarchy-voxtype-config'],
      ],
      'use_voxtype' => [
        ['omarchy-dictation-use', 'voxtype'],
      ],
      'use_superwhisper' => [
        ['omarchy-dictation-use', 'superwhisper'],
      ],
      'install_whisper' => () {
        final list = <List<String>>[
          ['sudo', 'pacman', '-S', '--needed', 'whisper.cpp'],
        ];
        final model = whisperStarterModels
            .where((m) => m['id'] == (target.isEmpty ? 'base' : target))
            .toList();
        if (model.isNotEmpty) {
          Directory(_managedWhisperDir).createSync(recursive: true);
          final dest = p.join(
            _managedWhisperDir,
            model.first['file'] as String,
          );
          final url = model.first['url'] as String;
          list.add(['curl', '-fL', '--progress-bar', '-o', dest, url]);
        }
        return list;
      }(),
      'update_whisper' => [
        ['sudo', 'pacman', '-Syu', '--needed', 'whisper.cpp'],
      ],
      'remove_whisper' => [
        ['sudo', 'pacman', '-Rns', 'whisper.cpp'],
      ],
      _ => const <List<String>>[],
    };
    final ok = desktop.runStepsInTerminal(steps, prompt);
    return {'ok': ok};
  }
}
