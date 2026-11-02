import 'dart:async';

import 'package:flutter/material.dart';
import 'app_look.dart';
import 'app_theme.dart' show corners;
import 'backend.dart' show failureText;
import 'core_client.g.dart';
import 'map_smart_card.dart' show SmartStatusIcon;

/// Notifies open Ask AI cards and Settings when dictation settings or setup change.
final dictationChanged = ValueNotifier<int>(0);

Map<String, dynamic> fallbackDictationSnapshot(Map<String, dynamic> settings) {
  final enabled = settings['dictation'] as bool? ?? true;
  final engine = settings['dictation_engine'] as String? ?? 'auto';
  final whisperModel = settings['dictation_whisper_model'] as String? ?? '';
  return {
    'enabled': enabled,
    'engine': engine,
    'whisper_model': whisperModel,
    'active': '',
    'active_label': '',
    'ready': false,
    'configured': false,
    'recording': false,
    'transcribing': false,
    'cost_hint': engine == 'online'
        ? 'Online dictation sends audio to an online provider and uses API credit. Local Whisper or Omarchy dictation is free and stays on this PC.'
        : '',
    'omarchy': const {
      'supported': false,
      'default_tool': '',
      'omarchy_dictation': false,
      'voxtype_installed': false,
      'superwhisper_configured': false,
      'monologue_installed': false,
      'ready': false,
      'configured': false,
      'label': 'Omarchy dictation',
    },
    'whisper': const {
      'program_installed': false,
      'can_install_program': true,
      'binary': '',
      'recorder_installed': false,
      'models': <Map<String, dynamic>>[],
      'active_model': '',
      'active_model_path': '',
      'catalog': <Map<String, dynamic>>[
        {
          'id': 'base',
          'file': 'ggml-base.bin',
          'label': 'Whisper base (148 MB · fast, any PC)',
          'size_mb': 148,
        },
        {
          'id': 'small',
          'file': 'ggml-small.bin',
          'label': 'Whisper small (488 MB · balanced)',
          'size_mb': 488,
        },
        {
          'id': 'turbo',
          'file': 'ggml-large-v3-turbo-q5_0.bin',
          'label': 'Whisper large-v3-turbo (574 MB · best accuracy)',
          'size_mb': 574,
        },
      ],
      'ready': false,
      'label': 'Local Whisper',
    },
    'local': const {
      'runtimes': <String>[],
      'models': <Map<String, dynamic>>[],
      'ready': false,
      'configured': false,
      'label': 'Local LLM',
    },
    'online': const {
      'provider': '',
      'ready': false,
      'cost_hint': '',
      'label': 'Online provider',
    },
  };
}

class DictationControls extends StatelessWidget {
  const DictationControls({
    super.key,
    required this.snapshot,
    required this.busy,
    required this.tr,
    required this.onEngineChanged,
    required this.onAction,
    required this.onRefresh,
    this.compact = false,
  });

  final Map<String, dynamic> snapshot;
  final bool busy;
  final String Function(String) tr;
  final ValueChanged<String> onEngineChanged;
  final Future<void> Function(String action, [String? target]) onAction;
  final VoidCallback onRefresh;
  final bool compact;

  static final _btnStyle = OutlinedButton.styleFrom(
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.sm,
      vertical: AppSpace.xs,
    ),
    textStyle: const TextStyle(fontSize: 12),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final engine = snapshot['engine'] as String? ?? 'auto';
    final active = snapshot['active'] as String? ?? '';
    final costHint = snapshot['cost_hint'] as String? ?? '';
    final omarchy = (snapshot['omarchy'] as Map? ?? const {})
        .cast<String, dynamic>();
    final whisper = (snapshot['whisper'] as Map? ?? const {})
        .cast<String, dynamic>();
    final local = (snapshot['local'] as Map? ?? const {})
        .cast<String, dynamic>();
    final online = (snapshot['online'] as Map? ?? const {})
        .cast<String, dynamic>();

    final omarchySupported =
        omarchy['supported'] == true || engine == 'omarchy';
    final showOmarchy =
        omarchySupported && (engine == 'auto' || engine == 'omarchy');
    final showWhisper = engine == 'auto' || engine == 'whisper';
    final showLocal = engine == 'local';
    final showOnline = engine == 'online' || active == 'online';

    final whisperModels = (whisper['models'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final activeWhisperModel = whisper['active_model'] as String? ?? '';
    final canInstallWhisper = whisper['can_install_program'] != false;
    final downloadedNames = {for (final m in whisperModels) '${m['name']}'};
    final catalog = (whisper['catalog'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final localModels = (local['models'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('dictation-engine-$engine'),
          initialValue:
              const {
                'auto',
                'omarchy',
                'whisper',
                'local',
                'online',
              }.contains(engine)
              ? engine
              : 'auto',
          isExpanded: true,
          decoration: InputDecoration(
            isDense: compact,
            labelText: tr('Dictation engine'),
          ),
          items: [
            DropdownMenuItem(
              value: 'auto',
              child: Text(tr('Automatic (best available on this PC)')),
            ),
            if (omarchySupported)
              DropdownMenuItem(
                value: 'omarchy',
                child: Text(
                  tr('Omarchy dictation & Monologue (free, on this PC)'),
                ),
              ),
            DropdownMenuItem(
              value: 'whisper',
              child: Text(tr('Local Whisper (free, on this PC)')),
            ),
            DropdownMenuItem(
              value: 'local',
              child: Text(tr('Local LLM speech model (free, on this PC)')),
            ),
            DropdownMenuItem(
              value: 'online',
              child: Text(tr('Online provider (uses API credit)')),
            ),
          ],
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) onEngineChanged(value);
                },
        ),
        if (costHint.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Material(
            key: const ValueKey('dictation-cost-warning'),
            color: colors.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(corners(context)),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2, right: AppSpace.sm),
                    child: SmartStatusIcon(level: 'hint', size: 15),
                  ),
                  Expanded(
                    child: Text(costHint, style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (showOmarchy) ...[
          const SizedBox(height: AppSpace.sm),
          if (omarchy['ready'] == true || engine == 'omarchy')
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Text(
                tr('Omarchy dictation types into the focused text field.'),
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
            ),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            children: [
              if (omarchy['voxtype_installed'] != true)
                OutlinedButton(
                  key: const ValueKey('dictation-install-voxtype'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('install_voxtype'),
                  child: Text(tr('Install Omarchy Voxtype…')),
                )
              else ...[
                if (omarchy['default_tool'] != 'voxtype')
                  OutlinedButton(
                    key: const ValueKey('dictation-use-voxtype'),
                    style: _btnStyle,
                    onPressed: busy ? null : () => onAction('use_voxtype'),
                    child: Text(tr('Use Voxtype')),
                  ),
                OutlinedButton(
                  key: const ValueKey('dictation-voxtype-model'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('voxtype_model'),
                  child: Text(tr('Voxtype model…')),
                ),
                OutlinedButton(
                  key: const ValueKey('dictation-voxtype-config'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('voxtype_config'),
                  child: Text(tr('Configure Voxtype…')),
                ),
                TextButton(
                  key: const ValueKey('dictation-remove-voxtype'),
                  onPressed: busy ? null : () => onAction('remove_voxtype'),
                  child: Text(tr('Remove Voxtype…')),
                ),
              ],
              if (omarchy['superwhisper_configured'] != true)
                OutlinedButton(
                  key: const ValueKey('dictation-install-superwhisper'),
                  style: _btnStyle,
                  onPressed: busy
                      ? null
                      : () => onAction('install_superwhisper'),
                  child: Text(tr('Set up Superwhisper…')),
                )
              else ...[
                if (omarchy['default_tool'] != 'superwhisper')
                  OutlinedButton(
                    key: const ValueKey('dictation-use-superwhisper'),
                    style: _btnStyle,
                    onPressed: busy ? null : () => onAction('use_superwhisper'),
                    child: Text(tr('Use Superwhisper')),
                  ),
                TextButton(
                  key: const ValueKey('dictation-remove-superwhisper'),
                  onPressed: busy
                      ? null
                      : () => onAction('remove_superwhisper'),
                  child: Text(tr('Remove Superwhisper…')),
                ),
              ],
              if (omarchy['monologue_installed'] != true)
                OutlinedButton(
                  key: const ValueKey('dictation-install-monologue'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('install_monologue'),
                  child: Text(tr('Install Omarchy Monologue…')),
                )
              else ...[
                OutlinedButton(
                  key: const ValueKey('dictation-open-monologue'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('open_monologue'),
                  child: Text(tr('Open Monologue')),
                ),
                TextButton(
                  key: const ValueKey('dictation-remove-monologue'),
                  onPressed: busy ? null : () => onAction('remove_monologue'),
                  child: Text(tr('Remove Monologue…')),
                ),
              ],
              if (omarchy['voxtype_installed'] == true ||
                  omarchy['superwhisper_configured'] == true ||
                  omarchy['monologue_installed'] == true)
                OutlinedButton(
                  key: const ValueKey('dictation-update-omarchy'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('update_omarchy'),
                  child: Text(tr('Update Omarchy dictation…')),
                ),
            ],
          ),
        ],
        if (showWhisper) ...[
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (whisper['program_installed'] != true && canInstallWhisper)
                OutlinedButton(
                  key: const ValueKey('dictation-install-whisper'),
                  style: _btnStyle,
                  onPressed: busy
                      ? null
                      : () => onAction('install_whisper', 'base'),
                  child: Text(tr('Install Whisper + base model…')),
                )
              else if (whisper['program_installed'] == true &&
                  canInstallWhisper) ...[
                OutlinedButton(
                  key: const ValueKey('dictation-update-whisper'),
                  style: _btnStyle,
                  onPressed: busy ? null : () => onAction('update_whisper'),
                  child: Text(tr('Update Whisper…')),
                ),
                TextButton(
                  key: const ValueKey('dictation-remove-whisper'),
                  onPressed: busy ? null : () => onAction('remove_whisper'),
                  child: Text(tr('Remove Whisper…')),
                ),
              ],
              for (final m in catalog)
                if (!downloadedNames.contains('${m['file']}'))
                  OutlinedButton(
                    key: ValueKey('dictation-download-${m['id']}'),
                    style: _btnStyle,
                    onPressed: busy
                        ? null
                        : () =>
                              onAction('download_whisper_model', '${m['id']}'),
                    child: Text('${tr('Download')}: ${m['label']}'),
                  ),
              TextButton(
                key: const ValueKey('dictation-refresh'),
                onPressed: busy ? null : onRefresh,
                child: Text(tr('Check again')),
              ),
            ],
          ),
          if (whisperModels.isNotEmpty) ...[
            const SizedBox(height: AppSpace.xs),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                for (final m in whisperModels)
                  InputChip(
                    key: ValueKey('dictation-model-chip-${m['name']}'),
                    visualDensity: VisualDensity.compact,
                    selected: m['name'] == activeWhisperModel,
                    onSelected: busy
                        ? null
                        : (_) =>
                              onAction('select_whisper_model', '${m['name']}'),
                    label: Text(
                      '${m['name']}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    onDeleted: m['managed'] == true && !busy
                        ? () => onAction('remove_whisper_model', '${m['name']}')
                        : null,
                    deleteButtonTooltipMessage: tr('Remove'),
                  ),
              ],
            ),
          ],
        ],
        if (showLocal) ...[
          const SizedBox(height: AppSpace.sm),
          if (localModels.isEmpty)
            Text(
              tr(
                'No speech model (such as Whisper) was found in your local LLMs yet.',
              ),
              style: const TextStyle(fontSize: 12),
            )
          else
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: [
                for (final m in localModels)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${m['runtime_name']} · ${m['model']}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
        ],
        if (showOnline && online['ready'] != true) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            tr(
              'No online transcription API key (OPENAI_API_KEY or GROQ_API_KEY) was found.',
            ),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class DictationSection extends StatefulWidget {
  const DictationSection({
    super.key,
    required this.settings,
    required this.busy,
    required this.tr,
    required this.onUpdate,
    this.client,
    this.initialSnapshot,
  });

  final Map<String, dynamic> settings;
  final bool busy;
  final String Function(String) tr;
  final Future<void> Function(Map<String, dynamic>) onUpdate;
  final CoreClient? client;
  final Map<String, dynamic>? initialSnapshot;

  @override
  State<DictationSection> createState() => _DictationSectionState();
}

class _DictationSectionState extends State<DictationSection> {
  Map<String, dynamic>? _snapshot;
  bool _recording = false;
  bool _transcribing = false;
  String? _recordingHandle;
  String _testMeta = '';
  String _testError = '';
  final _testField = TextEditingController();
  final _testFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _snapshot = widget.initialSnapshot;
    dictationChanged.addListener(_loadSnapshot);
    _loadSnapshot();
  }

  void _cancelActiveRecording() {
    if (!_recording) return;
    final handle = _recordingHandle;
    _recording = false;
    _recordingHandle = null;
    final client = widget.client;
    if (client != null) {
      unawaited(
        client
            .dictationStop(recording: handle, cancel: true)
            .then((_) {}, onError: (_) {}),
      );
    }
  }

  @override
  void didUpdateWidget(DictationSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSnapshot != oldWidget.initialSnapshot &&
        widget.initialSnapshot != null) {
      _snapshot = widget.initialSnapshot;
    }
    if (widget.settings['dictation'] == false && _recording) {
      _cancelActiveRecording();
    }
    if (widget.settings['dictation'] != oldWidget.settings['dictation'] ||
        widget.settings['dictation_engine'] !=
            oldWidget.settings['dictation_engine'] ||
        widget.settings['dictation_whisper_model'] !=
            oldWidget.settings['dictation_whisper_model']) {
      _loadSnapshot();
    }
  }

  @override
  void dispose() {
    _cancelActiveRecording();
    dictationChanged.removeListener(_loadSnapshot);
    _testField.dispose();
    _testFocus.dispose();
    super.dispose();
  }

  Future<void> _loadSnapshot() async {
    final client = widget.client;
    if (client == null) return;
    try {
      final snap = await client.dictationSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snap;
        _recording = snap['recording'] == true;
        _transcribing = snap['transcribing'] == true;
      });
    } catch (_) {}
  }

  Future<void> _runAction(String action, [String? target]) async {
    final client = widget.client;
    if (client == null) return;
    setState(() => _testError = '');
    try {
      await client.dictationRun(action: action, target: target);
      dictationChanged.value++;
      await _loadSnapshot();
    } catch (e) {
      if (!mounted) return;
      setState(() => _testError = failureText(widget.tr, e));
    }
  }

  Future<void> _toggleTestRecording() async {
    final client = widget.client;
    if (client == null || _transcribing) return;
    setState(() => _testError = '');
    if (!_recording) {
      _testFocus.requestFocus();
      try {
        final started = await client.dictationStart();
        if (!mounted) return;
        setState(() {
          _recording = true;
          _recordingHandle = started['recording'] as String?;
          _testMeta = '';
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _testError = failureText(widget.tr, e));
      }
      return;
    }
    // Keep focus on the test field so Omarchy dictation (Voxtype/Superwhisper)
    // types into it when stopping.
    _testFocus.requestFocus();
    final handle = _recordingHandle;
    setState(() {
      _recording = false;
      _recordingHandle = null;
      _transcribing = true;
    });
    try {
      final stopped = await client.dictationStop(recording: handle);
      if (!mounted) return;
      final text = (stopped['text'] as String? ?? '').trim();
      final elapsed = stopped['elapsed_ms'] as int? ?? 0;
      final engine = stopped['engine'] as String? ?? '';
      final typedByDesktop = stopped['typed_by_desktop'] == true;
      if (text.isNotEmpty) {
        _testField.text = text;
      }
      setState(() {
        _transcribing = false;
        _testMeta = typedByDesktop
            ? widget.tr('Omarchy dictation types into the focused text field.')
            : widget
                  .tr('Transcribed in {0} ms · {1}')
                  .replaceAll('{0}', '$elapsed')
                  .replaceAll('{1}', engine);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _transcribing = false;
        _testError = failureText(widget.tr, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    final colors = Theme.of(context).colorScheme;
    final base = _snapshot ?? fallbackDictationSnapshot(widget.settings);
    final enabled =
        widget.settings['dictation'] as bool? ??
        base['enabled'] as bool? ??
        true;
    final engine =
        widget.settings['dictation_engine'] as String? ??
        base['engine'] as String? ??
        'auto';
    final snap = {...base, 'enabled': enabled, 'engine': engine};
    final ready = snap['ready'] == true;
    final active = snap['active'] as String? ?? '';
    final activeLabel = snap['active_label'] as String? ?? active;

    final Widget badge;
    if (!enabled) {
      badge = Text(
        tr('Off'),
        key: const ValueKey('dictation-status-off'),
        style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
      );
    } else if (!ready) {
      badge = Row(
        key: const ValueKey('dictation-status-unconfigured'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SmartStatusIcon(level: 'hint', size: 15),
          const SizedBox(width: AppSpace.xs),
          Text(tr('On · not set up yet'), style: const TextStyle(fontSize: 12)),
        ],
      );
    } else if (active == 'online') {
      badge = Row(
        key: const ValueKey('dictation-status-online'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SmartStatusIcon(level: 'hint', size: 15),
          const SizedBox(width: AppSpace.xs),
          Text(
            tr('Ready · {0}').replaceAll('{0}', activeLabel),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      );
    } else {
      badge = Row(
        key: const ValueKey('dictation-status-ready'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const SmartStatusIcon(level: 'ok', size: 15),
          const SizedBox(width: AppSpace.xs),
          Text(
            tr('Ready · {0}').replaceAll('{0}', activeLabel),
            style: const TextStyle(fontSize: 12),
          ),
        ],
      );
    }

    final hintText = _transcribing
        ? tr('Transcribing…')
        : _recording
        ? tr('Listening… Click Stop when done.')
        : tr('Your dictated test text appears here…');

    return SectionCard(
      key: const ValueKey('settings-dictation-card'),
      title: tr('Dictation'),
      trailing: badge,
      child: ListTileTheme(
        contentPadding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('dictation-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Use dictation in Ask AI')),
              subtitle: Text(
                tr(
                  'Speak your question into the microphone in Ask AI instead of typing.',
                ),
              ),
              value: enabled,
              onChanged: widget.busy
                  ? null
                  : (value) async {
                      if (!value && _recording) {
                        _cancelActiveRecording();
                      }
                      await widget.onUpdate({'dictation': value});
                      dictationChanged.value++;
                    },
            ),
            if (enabled) ...[
              const SizedBox(height: AppSpace.sm),
              DictationControls(
                snapshot: snap,
                busy: widget.busy,
                tr: tr,
                onEngineChanged: (next) async {
                  await widget.onUpdate({'dictation_engine': next});
                  dictationChanged.value++;
                },
                onAction: _runAction,
                onRefresh: _loadSnapshot,
              ),
              const SizedBox(height: AppSpace.md),
              Material(
                key: const ValueKey('dictation-test-card'),
                color: colors.surfaceContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(corners(context)),
                  side: BorderSide(color: colors.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              tr('Test dictation'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          FilledButton.tonalIcon(
                            key: const ValueKey('dictation-test-button'),
                            onPressed:
                                !widget.busy &&
                                    !_transcribing &&
                                    (ready || _recording)
                                ? _toggleTestRecording
                                : null,
                            icon: _transcribing
                                ? const SizedBox(
                                    key: ValueKey(
                                      'dictation-test-transcribing',
                                    ),
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    _recording ? Icons.stop : Icons.mic,
                                    size: 16,
                                  ),
                            label: Text(
                              _transcribing
                                  ? tr('Transcribing…')
                                  : _recording
                                  ? tr('Stop')
                                  : tr('Speak a test sentence'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      if (ready ||
                          _recording ||
                          _transcribing ||
                          _testField.text.isNotEmpty)
                        TextField(
                          key: const ValueKey('dictation-test-field'),
                          controller: _testField,
                          focusNode: _testFocus,
                          minLines: 1,
                          maxLines: 3,
                          style: const TextStyle(fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: hintText,
                            border: const OutlineInputBorder(),
                          ),
                        )
                      else
                        InputDecorator(
                          key: const ValueKey('dictation-test-field'),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          child: Text(
                            hintText,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (_testMeta.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            _testMeta,
                            key: const ValueKey('dictation-test-meta'),
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      if (_testError.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpace.xs),
                          child: Text(
                            _testError,
                            key: const ValueKey('dictation-test-error'),
                            style: TextStyle(fontSize: 11, color: colors.error),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
