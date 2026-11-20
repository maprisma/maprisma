import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maprisma_core/maprisma_core.dart' show openWebPage, smartSource;
import 'app_look.dart';
import 'core_client.g.dart';
import 'backend.dart' show failureText;
import 'mic_button.dart';
import 'task_card.dart';
import 'voice_input.dart';

/// The draft outlives a review, so Cancel preserves edits and AI provenance.
class ProviderConfigurationView extends StatefulWidget {
  const ProviderConfigurationView({
    super.key,
    required this.facts,
    required this.client,
    required this.draft,
    required this.tr,
    required this.onClose,
    required this.onApply,
    this.onUndo,
    this.onTune,
  });
  final Map<String, dynamic> facts, draft;
  final CoreClient client;
  final String Function(String) tr;
  final VoidCallback onClose;
  final Future<bool> Function(
    Map<String, dynamic> plan,
    Map<String, dynamic> options,
  )
  onApply;
  final Future<bool> Function(String undo)? onUndo;
  final void Function(List<String>? models)? onTune;
  @override
  State<ProviderConfigurationView> createState() =>
      _ProviderConfigurationViewState();
}

class _ProviderConfigurationViewState extends State<ProviderConfigurationView> {
  late Map<String, dynamic> _facts;
  Map<String, dynamic> get draft => widget.draft;
  Map<String, dynamic> get values => draft['values'] as Map<String, dynamic>;
  String get model => '${draft['model'] ?? _facts['model']}';
  String get profile =>
      '${draft['profile'] ?? _facts['profile'] ?? 'balanced'}';
  String get providerKey => '${_facts['key']}';
  String tr(String value) => widget.tr(value);
  final _focus = TextEditingController();
  final _focusNode = FocusNode();
  final _editors = <String, TextEditingController>{};
  String _partial = '', _message = '';
  String? _task, _helper;
  bool _working = false, _checking = false, _advanced = false, _web = false;
  int _generation = 0, _validation = 0;
  Timer? _debounce;
  Map<String, dynamic> _check = {};
  VoiceStatus _voice = VoiceStatus.missing;
  List<Map> get schema => (_facts['schema'] as List? ?? const []).cast<Map>();
  List<Map> get helpers => (_facts['helpers'] as List? ?? const []).cast<Map>();
  Map get helper =>
      helpers.where((h) => h['command'] == _helper).firstOrNull ?? const {};
  Map get current => _facts['current'] as Map? ?? const {};
  bool get writable => _facts['writable'] == true;
  List get errors => _check['errors'] as List? ?? const [];
  List get warnings => _check['warnings'] as List? ?? const [];
  Map get fit => _check['fit'] as Map? ?? _facts['fit'] as Map? ?? const {};
  bool get changed =>
      values.entries.any((e) => e.value == null || e.value != current[e.key]);
  @override
  void initState() {
    super.initState();
    _facts = draft['_facts'] as Map<String, dynamic>? ?? widget.facts;
    draft.putIfAbsent('values', () => <String, dynamic>{});
    draft['values'] = Map<String, dynamic>.from(draft['values'] as Map);
    _helper = helpers.firstOrNull?['command'] as String?;
    _voiceStatus();
    final reload = draft.remove('_reload');
    if (reload == true || reload == 'facts') {
      unawaited(_load(model, profile, preserveDraft: reload == 'facts'));
    } else {
      _validate(rebuild: false);
    }
  }

  Future<void> _voiceStatus() async {
    final status = await VoiceInput.available(fresh: true);
    if (mounted) setState(() => _voice = status);
  }

  @override
  void dispose() {
    _generation++;
    _validation++;
    _debounce?.cancel();
    final task = _task;
    if (task != null) {
      unawaited(
        widget.client
            .tasksCancel(task: task)
            .catchError((_) => <String, dynamic>{}),
      );
    }
    for (final controller in _editors.values) {
      controller.dispose();
    }
    _focus.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _job(
    Future<Map<String, dynamic>> started,
    int generation,
  ) async {
    final first = await started;
    if (first['task'] is! String) {
      throw StateError('${first['error'] ?? 'No configuration task'}');
    }
    final task = first['task'] as String;
    if (!mounted || generation != _generation) {
      await widget.client.tasksCancel(task: task);
      throw StateError('Stopped');
    }
    _task = task;
    try {
      while (mounted && generation == _generation) {
        final status = await widget.client.tasksStatus(task: task);
        if (status['state'] == 'done') {
          return Map<String, dynamic>.from(status['result'] as Map);
        }
        if (status['state'] != 'running') {
          throw StateError('${status['text'] ?? 'Stopped'}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      throw StateError('Stopped');
    } finally {
      if (_task == task) _task = null;
    }
  }

  Future<void> _cancel() async {
    _generation++;
    final task = _task;
    _task = null;
    if (task != null) await widget.client.tasksCancel(task: task);
    if (mounted) setState(() => _working = false);
  }

  Future<void> _load(
    String nextModel,
    String nextProfile, {
    bool preserveDraft = false,
  }) async {
    final generation = ++_generation;
    if (!preserveDraft) _dropProposal();
    setState(() {
      _working = true;
      _message = '';
    });
    try {
      final facts = await _job(
        widget.client.modelsConfig(
          key: providerKey,
          model: nextModel,
          profile: nextProfile,
        ),
        generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _facts = facts;
        draft['_facts'] = facts;
        draft['model'] = facts['model'];
        draft['profile'] = nextProfile;
        if (!preserveDraft) {
          draft['values'] = <String, dynamic>{};
          draft.remove('reasons');
        }
        _check = {};
        _helper = helpers.any((h) => h['command'] == _helper)
            ? _helper
            : helpers.firstOrNull?['command'] as String?;
        if (helper['web_search'] != true) _web = false;
        _syncEditors();
      });
      _validate();
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _message = tr('Configuration could not be read.'));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _working = false);
      }
    }
  }

  void _syncEditors() {
    for (final s in schema) {
      final id = '${s['id']}',
          v = values.containsKey(id) ? values[id] : current[id];
      final controller = _editors[id];
      if (controller != null) controller.text = v is num ? '$v' : '';
    }
  }

  void _dropProposal() {
    draft.remove('config_proposal');
    draft.remove('reasons');
    draft.remove('summary');
    draft.remove('sources');
  }

  void _edit(String id, dynamic value) {
    setState(() {
      _dropProposal();
      values[id] = value;
    });
    _validate();
  }

  void _useDefault(String id) {
    final overrides = _facts['overrides'] as List?;
    if (overrides != null && !overrides.contains(id)) {
      setState(() {
        _dropProposal();
        values.remove(id);
        _syncEditors();
      });
      _validate();
    } else {
      _edit(id, null);
      _syncEditors();
    }
  }

  bool get _missingModel =>
      schema.firstOrNull?['scope'] == 'per_model' && model.isEmpty;
  void _validate({bool rebuild = true}) {
    _debounce?.cancel();
    final generation = ++_validation;
    if (rebuild) {
      setState(() => _checking = true);
    } else {
      _checking = true;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      try {
        final result = await widget.client.modelsConfigCheck(
          key: providerKey,
          model: model,
          values: Map.of(values),
        );
        if (!mounted || generation != _validation) return;
        setState(() {
          _check = result;
          _checking = false;
          if (result['error'] == 'stale') {
            _check = {
              'errors': [
                {'text': 'Read the configuration again before applying.'},
              ],
            };
            _message = tr('Read the configuration again before applying.');
          }
        });
      } catch (_) {
        if (mounted && generation == _validation) {
          setState(() {
            _checking = false;
            _message = tr('Configuration could not be checked.');
            _check = {
              'errors': [
                {'text': _message},
              ],
            };
          });
        }
      }
    });
  }

  void _recommended() {
    setState(() {
      _dropProposal();
      draft['values'] = <String, dynamic>{
        for (final r
            in (_facts['recommended'] as List? ?? const []).cast<Map>())
          if (schema.any((s) => s['id'] == r['id'] && s['verified'] == true))
            '${r['id']}': r['recommended'],
      };
      _syncEditors();
    });
    _validate();
  }

  Future<void> _ask() async {
    final generation = ++_generation;
    setState(() {
      _working = true;
      _message = '';
    });
    try {
      final result = await _job(
        widget.client.modelsConfigAsk(
          key: providerKey,
          model: model,
          profile: profile,
          command: _helper!,
          focus: _focus.text,
          webSearch: _web && helper['web_search'] == true,
        ),
        generation,
      );
      if (!mounted || generation != _generation) return;
      if (result['error'] != null) {
        if (result['error'] == 'stale') {
          _staleAsk();
          return;
        }
        setState(
          () =>
              _message = tr('The helper did not return a valid configuration.'),
        );
        return;
      }
      setState(() {
        draft['values'] = Map<String, dynamic>.from(result['values'] as Map);
        for (final key in [
          'config_proposal',
          'reasons',
          'summary',
          'sources',
        ]) {
          if (result.containsKey(key)) draft[key] = result[key];
        }
        _syncEditors();
      });
      _validate();
    } catch (error) {
      if (mounted && generation == _generation) {
        if (error is StateError && error.message == 'stale') {
          _staleAsk();
        } else {
          setState(
            () => _message = tr(
              'The helper did not return a valid configuration.',
            ),
          );
        }
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _working = false);
      }
    }
  }

  void _staleAsk() {
    _debounce?.cancel();
    ++_validation;
    setState(() {
      _checking = false;
      _message = tr('Read the configuration again before applying.');
      _check = {
        'errors': [
          {'text': 'Read the configuration again before applying.'},
        ],
      };
    });
  }

  Future<void> _apply() async {
    setState(() => _working = true);
    try {
      final preview = await widget.client.modelsConfigPreview(
        key: providerKey,
        model: model,
        values: Map.of(values),
        configProposal: draft['config_proposal'] as String?,
      );
      if (!mounted) return;
      if (preview['ok'] != true) {
        setState(() {
          final message = preview['error'] == 'stale'
              ? 'Read the configuration again before applying.'
              : 'Configuration could not be checked.';
          _check =
              preview['errors'] is List &&
                  (preview['errors'] as List).isNotEmpty
              ? preview
              : {
                  'errors': [
                    {'text': message},
                  ],
                };
          _message = tr(message);
        });
        return;
      }
      final applied = await widget.onApply(preview, {
        'key': providerKey,
        'model': model,
        'restart': _facts['restart'],
        'can_control': _facts['can_control'],
        'can_reload': _facts['can_reload'],
        'running': _facts['running'],
      });
      if (applied && mounted) {
        draft['values'] = <String, dynamic>{};
        _dropProposal();
        await _load(model, profile);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = failureText(tr, error));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _undo() async {
    final token = draft['_undo'] as String?;
    if (token == null || widget.onUndo == null) return;
    setState(() => _working = true);
    try {
      if (await widget.onUndo!(token)) {
        draft.remove('_undo');
        await _load(model, profile);
      }
    } catch (error) {
      if (mounted) setState(() => _message = failureText(tr, error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String display(dynamic value) =>
      value == null ? tr('Engine default') : '$value';
  String gb(dynamic value) =>
      '${((value is num ? value : 0) / (1 << 30)).toStringAsFixed(1)} GB';
  Map recommended(String id) =>
      (_facts['recommended'] as List? ?? const [])
          .cast<Map>()
          .where((r) => r['id'] == id)
          .firstOrNull ??
      const {};

  void _step(Map field, int direction) {
    final id = '${field['id']}',
        value = values.containsKey(id) ? values[id] : current[id];
    final range = field['range'] as List? ?? const [0, 10000000];
    final amount = field['type'] == 'float'
        ? 0.05
        : field['role'] == 'context'
        ? 4096
        : const {'batch', 'ubatch'}.contains(field['role'])
        ? 64
        : 1;
    final next = ((value is num ? value : range[0] as num) + direction * amount)
        .clamp(range[0] as num, range[1] as num);
    final dynamic typed = field['type'] == 'float'
        ? double.parse(next.toStringAsFixed(2))
        : next.toInt();
    _edit(id, typed);
    final controller = _editors[id];
    if (controller != null) {
      controller.value = TextEditingValue(
        text: '$typed',
        selection: TextSelection.collapsed(offset: '$typed'.length),
      );
    }
  }

  Widget _editor(Map s) {
    final id = '${s['id']}',
        value = values.containsKey(id) ? values[id] : current[id];
    final enabled = !_working && !_missingModel && s['verified'] == true;
    Widget editor;
    if (s['type'] == 'bool') {
      editor = Switch(
        key: ValueKey('config-$id'),
        value: value == true,
        onChanged: enabled ? (v) => _edit(id, v) : null,
      );
    } else if (s['type'] == 'enum') {
      final choices = s['values'] as List;
      editor = DropdownButtonFormField<Object>(
        key: ValueKey('config-$id'),
        initialValue: choices.contains(value) ? value : null,
        hint: Text(tr('Default')),
        isExpanded: true,
        items: [
          for (final c in choices)
            DropdownMenuItem(value: c, child: Text('$c')),
        ],
        onChanged: enabled ? (v) => _edit(id, v) : null,
      );
    } else {
      final special = s['special'] as List? ?? const [];
      final numeric = value is num ? value.toString() : '';
      editor = Row(
        children: [
          Expanded(
            child: TextFormField(
              key: ValueKey('config-$id'),
              controller: _editors.putIfAbsent(
                id,
                () => TextEditingController(text: numeric),
              ),
              enabled: enabled,
              keyboardType: TextInputType.numberWithOptions(
                decimal: s['type'] == 'float',
                signed: special.any((v) => v is num && v < 0),
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: special.contains(value)
                    ? '$value'
                    : value == null
                    ? tr('Default')
                    : tr('Value'),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('decrease-$id'),
                      tooltip: tr('Decrease'),
                      visualDensity: VisualDensity.compact,
                      onPressed: enabled ? () => _step(s, -1) : null,
                      icon: const Icon(Icons.remove, size: 16),
                    ),
                    IconButton(
                      key: ValueKey('increase-$id'),
                      tooltip: tr('Increase'),
                      visualDensity: VisualDensity.compact,
                      onPressed: enabled ? () => _step(s, 1) : null,
                      icon: const Icon(Icons.add, size: 16),
                    ),
                  ],
                ),
              ),
              onChanged: (text) {
                final parsed = s['type'] == 'float'
                    ? double.tryParse(text)
                    : int.tryParse(text);
                _edit(id, parsed ?? text);
              },
            ),
          ),
          for (final v in special)
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.xs),
              child: ChoiceChip(
                key: ValueKey('special-$id-$v'),
                label: Text('$v'),
                selected: value == v,
                onSelected: enabled
                    ? (_) {
                        _edit(id, v);
                        _syncEditors();
                      }
                    : null,
              ),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        editor,
        if (s['verified'] != true)
          Text(
            tr('Not verified on this PC'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (s['scope'] == 'default' && model != '*')
          TextButton(
            key: ValueKey('default-$id'),
            onPressed:
                enabled &&
                    (((_facts['overrides'] as List?)?.contains(id) ?? true) ||
                        values.containsKey(id))
                ? () => _useDefault(id)
                : null,
            child: Text(tr('Use the default')),
          ),
      ],
    );
  }

  Widget _row(Map s, bool wide) {
    final id = '${s['id']}',
        r = recommended(id),
        changed =
            values.containsKey(id) &&
            (values[id] == null || values[id] != current[id]);
    final reason = (draft['reasons'] as Map?)?[id] ?? r['reason'] ?? '';
    final fromAi = draft['config_proposal'] != null && values.containsKey(id);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('${s['label']}'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: changed ? FontWeight.bold : null,
          ),
        ),
        if (fromAi)
          Text(
            tr('From Ask AI'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
      ],
    );
    final recommendation = Tooltip(
      message: tr('$reason'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            r['source'] == 'measured'
                ? Icons.science_outlined
                : Icons.calculate_outlined,
            size: 16,
          ),
          const SizedBox(width: AppSpace.xs),
          Flexible(child: Text(display(r['recommended']))),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: title),
                Expanded(flex: 2, child: Text(display(current[id]))),
                Expanded(flex: 3, child: recommendation),
                Expanded(flex: 3, child: _editor(s)),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.lg,
                  children: [
                    Text('${tr('Current')}: ${display(current[id])}'),
                    Text('${tr('Recommended')}: ${display(r['recommended'])}'),
                  ],
                ),
                const SizedBox(height: AppSpace.sm),
                _editor(s),
              ],
            ),
    );
  }

  Widget _fields(bool advanced) => LayoutBuilder(
    builder: (context, box) {
      final fields = schema
          .where((s) => (s['importance'] == 'advanced') == advanced)
          .toList();
      final specialCount = fields.fold<int>(0, (count, field) {
        final choices = (field['special'] as List? ?? const []).length;
        return choices > count ? choices : count;
      });
      // The last column needs room for text, both step buttons and selected
      // special chips. Stack rows before that column squeezes the input away.
      final editorMinimum = 176.0 + specialCount * 80;
      final wide =
          box.maxWidth >= 640 && box.maxWidth * 3 / 11 >= editorMinimum;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (wide)
            Row(
              children: [
                Expanded(flex: 3, child: Text(tr('Setting'))),
                Expanded(flex: 2, child: Text(tr('Current'))),
                Expanded(flex: 3, child: Text(tr('Recommended'))),
                Expanded(flex: 3, child: Text(tr('Your value'))),
              ],
            ),
          for (final s in fields) _row(s, wide),
        ],
      );
    },
  );
  Widget _fit() {
    final colors = Theme.of(context).colorScheme;
    final available = fit['available'] as num? ?? 0,
        total = fit['total'] as num? ?? 0;
    final color = errors.isNotEmpty
        ? colors.error
        : warnings.isNotEmpty
        ? StatusColors.warn
        : colors.primary;
    return SectionCard(
      title: tr('Memory estimate'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: available > 0 ? (total / available).clamp(0, 1) : 0,
            color: color,
            minHeight: 8,
          ),
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.sm,
            children: [
              Text('${tr('Model weights')}: ${gb(fit['weights'])}'),
              Text('${tr('KV cache')}: ${gb(fit['kv'])}'),
              Text('${tr('Reserve')}: ${gb(fit['reserve'])}'),
              Text(
                '${tr(fit['basis'] == 'ram' ? 'RAM available' : 'Video memory available')}: ${gb(available)}',
              ),
            ],
          ),
          for (final e in errors)
            Text(tr('${e['text']}'), style: TextStyle(color: colors.error)),
          for (final w in warnings) Text(tr('${w['text']}')),
        ],
      ),
    );
  }

  Widget _ai() {
    final enabled = !_working && !_missingModel && helpers.isNotEmpty;
    return SectionCard(
      title: tr('Ask AI'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (helpers.isNotEmpty)
                DropdownButton<String>(
                  value: _helper,
                  items: [
                    for (final h in helpers)
                      DropdownMenuItem(
                        value: '${h['command']}',
                        child: Text('${h['name']}'),
                      ),
                  ],
                  onChanged: enabled
                      ? (v) => setState(() {
                          _helper = v;
                          if (helper['web_search'] != true) _web = false;
                        })
                      : null,
                ),
              OutlinedButton.icon(
                key: const ValueKey('config-ask'),
                onPressed: enabled ? _ask : null,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text(tr('Ask AI')),
              ),
              if (_working)
                TextButton(onPressed: _cancel, child: Text(tr('Cancel'))),
            ],
          ),
          TextField(
            key: const ValueKey('config-focus'),
            controller: _focus,
            focusNode: _focusNode,
            maxLength: 500,
            enabled: !_working,
            decoration: InputDecoration(
              labelText: tr('What matters most?'),
              counterText: '',
              helperText: _partial.isEmpty ? null : _partial,
              suffixIcon: MicButton(
                appId: 'com.maprisma.Maprisma',
                tr: tr,
                controller: _focus,
                focusNode: _focusNode,
                enabled: !_working,
                onPartial: (v) {
                  if (mounted) setState(() => _partial = v);
                },
                onFinal: (text) {
                  insertDictatedText(_focus, text);
                  final cut = String.fromCharCodes(_focus.text.runes.take(500));
                  if (cut != _focus.text) {
                    _focus.value = TextEditingValue(
                      text: cut,
                      selection: TextSelection.collapsed(offset: cut.length),
                    );
                  }
                },
              ),
            ),
          ),
          if (_voice.usable)
            Text(
              '${tr('Dictation engine')} · ${_voice.engine}${const {'whisper', 'whisper.cpp', 'local'}.contains(_voice.engine) ? '' : ' · ${tr('Online dictation may use API credit.')}'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          CheckboxListTile(
            key: const ValueKey('config-web'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr('Search the web for guidance')),
            value: _web,
            subtitle: Text(
              tr(
                helper['web_search'] == true
                    ? 'Uses the selected helper’s web search and may use more tokens.'
                    : 'Choose a helper with web research to use this.',
              ),
            ),
            onChanged: enabled && helper['web_search'] == true
                ? (v) => setState(() => _web = v == true)
                : null,
          ),
          if (helpers.isEmpty)
            Text(
              tr('Choose an available AI helper to ask for a configuration.'),
            ),
          if (draft['summary'] is String) Text('${draft['summary']}'),
          for (final source in draft['sources'] as List? ?? const [])
            if (source is String && smartSource(source))
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    if (!openWebPage(
                      source,
                      Platform.environment['PATH'],
                      Directory.current.path,
                    )) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text(tr('Could not open the link.'))),
                      );
                    }
                  },
                  child: Text(source),
                ),
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hardware = _facts['hardware'] as Map? ?? const {};
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.goBack): widget.onClose,
      },
      child: TaskReview(
        title: Text('${tr('Configuration')} · ${_facts['runtime']}'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionCard(
              child: Wrap(
                spacing: AppSpace.xl,
                runSpacing: AppSpace.sm,
                children: [
                  Text(
                    '${hardware['gpu'] ?? tr('CPU')} · ${gb(hardware['vram_total'])}',
                  ),
                  Text(
                    '${tr('RAM available')}: ${gb(hardware['ram_available'])}',
                  ),
                  Text(
                    '${tr('Physical cores')}: ${hardware['physical_cores'] ?? '—'}',
                  ),
                  if (providerKey == 'llamacpp' &&
                      '${_facts['build'] ?? ''}'.isNotEmpty)
                    Text(
                      '${tr('Build')}: ${const {'rocm': 'ROCm', 'vulkan': 'Vulkan', 'cuda': 'CUDA', 'cpu': 'CPU'}[_facts['build']] ?? _facts['build']}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                for (final p in const {
                  'balanced': 'Balanced',
                  'long_context': 'Long context',
                  'fast': 'Fast',
                  'several_agents': 'Several agents',
                }.entries)
                  ChoiceChip(
                    key: ValueKey('profile-${p.key}'),
                    label: Text(tr(p.value)),
                    selected: profile == p.key,
                    onSelected: _working ? null : (_) => _load(model, p.key),
                  ),
              ],
            ),
            if (schema.firstOrNull?['scope'] != 'global')
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.md),
                child: DropdownButtonFormField<String>(
                  key: ValueKey('config-model-$model'),
                  initialValue: model.isEmpty ? null : model,
                  decoration: InputDecoration(labelText: tr('Model')),
                  items: [
                    for (final name
                        in _facts['scope_models'] as List? ?? const [])
                      DropdownMenuItem(
                        value: '$name',
                        child: Text(
                          name == '*' ? tr('All models (default)') : '$name',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _working
                      ? null
                      : (v) {
                          if (v != null) _load(v, profile);
                        },
                ),
              ),
            const SizedBox(height: AppSpace.lg),
            if (!writable)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: Text(
                  tr(
                    '${_facts['read_only_reason'] ?? 'This provider offers configuration advice'}',
                  ),
                ),
              ),
            SectionCard(
              title: tr('Model configuration'),
              child: _fields(false),
            ),
            const SizedBox(height: AppSpace.lg),
            SectionCard(
              title: tr('Advanced'),
              trailing: IconButton(
                key: const ValueKey('config-advanced'),
                tooltip: tr('Advanced'),
                icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more),
                onPressed: () => setState(() => _advanced = !_advanced),
              ),
              child: _advanced
                  ? _fields(true)
                  : Text(tr('Threads, batches and other settings')),
            ),
            const SizedBox(height: AppSpace.lg),
            _fit(),
            const SizedBox(height: AppSpace.lg),
            if (!writable && (_check['snippet'] ?? _facts['snippet']) is String)
              SectionCard(
                title: tr('Configuration example'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText('${_check['snippet'] ?? _facts['snippet']}'),
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton.icon(
                        key: const ValueKey('copy-config-snippet'),
                        onPressed: () => Clipboard.setData(
                          ClipboardData(
                            text: '${_check['snippet'] ?? _facts['snippet']}',
                          ),
                        ),
                        icon: const Icon(Icons.copy),
                        label: Text(tr('Copy')),
                      ),
                    ),
                  ],
                ),
              ),
            for (final note in _facts['notes'] as List? ?? const [])
              Text(tr('$note')),
            if (_working) const LinearProgressIndicator(),
            if (_message.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _message,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _working ? null : () => _load(model, profile),
                    child: Text(tr('Read again')),
                  ),
                ],
              ),
            const SizedBox(height: AppSpace.lg),
            _ai(),
          ],
        ),
        actions: [
          if (widget.onTune != null)
            TextButton(
              key: const ValueKey('tune-all'),
              onPressed: _working
                  ? null
                  : () => widget.onTune!(model == '*' ? null : [model]),
              child: Text(tr('Measure and tune')),
            ),
          TextButton(
            key: const ValueKey('config-reset'),
            onPressed: _working
                ? null
                : () {
                    setState(() {
                      _dropProposal();
                      draft['values'] = <String, dynamic>{};
                      _syncEditors();
                    });
                    _validate();
                  },
            child: Text(tr('Reset')),
          ),
          TextButton(
            key: const ValueKey('config-undo'),
            onPressed:
                _working || draft['_undo'] == null || widget.onUndo == null
                ? null
                : _undo,
            child: Text(tr('Undo')),
          ),
          OutlinedButton(
            key: const ValueKey('config-recommended'),
            onPressed: _working || _missingModel ? null : _recommended,
            child: Text(tr('Use recommended')),
          ),
          if (writable)
            FilledButton(
              key: const ValueKey('config-apply'),
              onPressed: _working || _checking || errors.isNotEmpty || !changed
                  ? null
                  : _apply,
              child: Text(tr('Apply')),
            ),
        ],
      ),
    );
  }
}
