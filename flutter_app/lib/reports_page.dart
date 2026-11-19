import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;

import 'activity_log_pane.dart';
import 'app_look.dart';
import 'core_client.g.dart';
import 'mic_button.dart';
import 'reports_output.dart';
import 'history_import_controller.dart';
import 'reports_help.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({
    super.key,
    required this.client,
    required this.tr,
    required this.tab,
    required this.onTab,
    required this.onBack,
    required this.settings,
    required this.onUpdate,
    required this.localHelperReady,
    required this.active,
    this.historyImport,
  });

  final CoreClient client;
  final String Function(String) tr;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onBack;
  final Map<String, dynamic> settings;
  final Future<void> Function(Map<String, dynamic>) onUpdate;
  final bool localHelperReady;
  final bool active;
  final HistoryImportController? historyImport;

  @override
  State<ReportsPage> createState() => ReportsPageState();
}

class ReportsPageState extends State<ReportsPage> {
  late final _history = widget.historyImport ?? HistoryImportController();
  List<Map<String, dynamic>> _importSources = [];
  bool _helpOpen = false;
  final _focus = TextEditingController();
  final _focusNode = FocusNode();
  String _partialFocus = '';
  final _project = TextEditingController();
  final _source = TextEditingController();
  final _title = TextEditingController();
  final _search = TextEditingController();
  final _log = GlobalKey<ActivityLogPaneState>();
  Map<String, dynamic>? _helpers, _draft, _library, _opened;
  String? _helper, _draftId, _topicError, _libraryError;
  Future<String>? _starting;
  int _generation = 0;
  bool _running = false, _confirming = false, _saving = false;
  bool _libraryLoading = false;
  int _libraryRequest = 0;
  DateTimeRange? _range;
  Timer? _searchTimer;
  String tr(String key) => widget.tr(key);
  CoreClient get client => widget.client;

  @override
  void initState() {
    super.initState();
    _history.addListener(_importChanged);
    unawaited(_loadImportSources());
    _loadTab(widget.tab);
  }

  @override
  void didUpdateWidget(ReportsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tab != widget.tab) {
      if (oldWidget.tab == 1) _partialFocus = '';
      _loadTab(widget.tab);
    }
  }

  @override
  void dispose() {
    _history.removeListener(_importChanged);
    if (widget.historyImport == null) _history.dispose();
    _searchTimer?.cancel();
    _focusNode.dispose();
    for (final c in [_focus, _project, _source, _title, _search]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadImportSources() async {
    try {
      final report = await client.activitylogReport();
      if (mounted) {
        setState(
          () => _importSources = (report['import_sources'] as List? ?? [])
              .cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      /* The Log tab exposes read failures with retry. */
    }
  }

  void _importChanged() {
    if (!mounted) return;
    setState(() {});
    if (!_history.running) {
      unawaited(_log.currentState?.refresh());
      unawaited(_loadImportSources());
    }
  }

  Future<void> showHelp() async {
    if (_helpOpen || ModalRoute.of(context)?.isCurrent != true) return;
    _helpOpen = true;
    try {
      await _loadImportSources();
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        await showReportingHelp(context, client, tr, _importSources);
      }
    } finally {
      _helpOpen = false;
    }
  }

  Future<void> _collectHistory() async {
    for (final (key, title) in [
      ('ai_activity_log', 'AI activity log'),
      ('ai_activity_import', 'Collect activity from agent history'),
    ]) {
      if (!mounted) return;
      if (widget.settings[key] == false ||
          key == 'ai_activity_log' && widget.settings[key] != true) {
        if (!await _confirm(title, 'Switch on') || !mounted) return;
        try {
          await widget.onUpdate({key: true});
          if (!mounted) return;
        } catch (_) {
          if (mounted) setState(() => _history.error = 'operation_failed');
          return;
        }
      }
    }
    if (mounted) await _history.collect(client);
  }

  Widget _historyStatus() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Tooltip(
        message: tr('Collect activity from outside Maprisma'),
        child: OutlinedButton.icon(
          onPressed: _history.running ? null : _collectHistory,
          icon: _history.running
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.history),
          label: Text(tr('Collect history')),
        ),
      ),
      if (_history.running && _history.progress.isNotEmpty)
        Text(_history.progress),
      if (_history.error != null)
        Text(
          tr(switch (_history.error) {
            'log_off' => 'Turn on the activity log to collect entries.',
            'import_off' => 'Collect activity from agent history',
            'import_running' => 'History collection is already running.',
            _ => 'Could not collect history.',
          }),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      for (final source in _history.result?['sources'] as List? ?? const [])
        Text(
          "${source['name']}: ${tr('{0} sessions, {1} new, {2} updated, {3} skipped').replaceAll('{0}', '${source['sessions']}').replaceAll('{1}', '${source['added']}').replaceAll('{2}', '${source['updated']}').replaceAll('{3}', '${source['skipped']}')} · ${tr(switch (source['status']) {
            'unsupported' => 'Unsupported',
            'unavailable' => 'Unavailable',
            'corrupt' => 'Damaged history',
            'partial' => 'Partial',
            _ => 'Finished',
          })}",
        ),
    ],
  );

  void _loadTab(int tab) {
    if (tab == 1) unawaited(_loadHelpers());
    if (tab == 2) unawaited(_loadLibrary());
  }

  String _code(Object error) =>
      error is ServiceError ? error.code : 'operation_failed';

  Future<void> _loadHelpers() async {
    try {
      final value = await client.reportsHelpers();
      if (!mounted) return;
      setState(() {
        _helpers = value;
        if (!(value['helpers'] as List).any((h) => h['command'] == _helper)) {
          _helper = value['chosen'] as String?;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _topicError = _code(e));
    }
  }

  Future<void> _loadLibrary({int? cursor}) async {
    final request = ++_libraryRequest;
    setState(() {
      _libraryLoading = true;
      _libraryError = null;
    });
    try {
      final value = await client.reportsList(
        query: _search.text,
        cursor: cursor,
      );
      if (!mounted || request != _libraryRequest) return;
      setState(() {
        _library = value;
        _libraryLoading = false;
      });
    } catch (e) {
      if (!mounted || request != _libraryRequest) return;
      setState(() {
        _library = null;
        _libraryError = _code(e);
        _libraryLoading = false;
      });
    }
  }

  Future<bool> _confirm(String question, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(tr(question)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('Back')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr(action)),
            ),
          ],
        ),
      ) ==
      true;

  Future<bool> allowExit() async {
    if (!_running) return true;
    if (_confirming) return false;
    _confirming = true;
    try {
      if (!await _confirm('Cancel the report?', 'Cancel report')) return false;
      if (!mounted) return false;
      try {
        final task = await _starting;
        if (task != null && _running) await client.tasksCancel(task: task);
      } catch (e) {
        if (_running && mounted) setState(() => _topicError = _code(e));
        return !_running;
      }
      _generation++;
      if (mounted) {
        setState(() {
          _running = false;
          _starting = null;
        });
      }
      return true;
    } finally {
      _confirming = false;
    }
  }

  String? _optional(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _generate() async {
    final helper = _helper;
    if (helper == null || _running) return;
    final generation = ++_generation;
    setState(() {
      _running = true;
      _topicError = null;
      _draft = null;
      _draftId = null;
    });
    try {
      final starting = _starting = client
          .reportsGenerate(
            helper: helper,
            fromDay: reportDay(_range?.start),
            throughDay: reportDay(_range?.end),
            focus: _optional(_focus),
            source: _optional(_source),
            project: _optional(_project),
          )
          .then((result) => result['task'] as String);
      final task = await starting;
      if (generation != _generation) return;
      if (!mounted) {
        await client.tasksCancel(task: task);
        return;
      }
      while (mounted && generation == _generation) {
        final status = await client.tasksStatus(task: task);
        if (!mounted || generation != _generation) return;
        if (status['state'] == 'done') {
          final value = status['result'] as Map;
          final draft = value['draft'] as Map<String, dynamic>?;
          setState(() {
            _draft = draft;
            _draftId = value['draft_id'] as String?;
            _topicError = value['code'] as String?;
            _title.text = draft?['title'] as String? ?? '';
          });
          break;
        }
        if (status['state'] != 'running') {
          if (status['state'] != 'stopped') {
            setState(() => _topicError = 'helper_failed');
          }
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _topicError = _code(e));
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _starting = null;
          _running = false;
        });
      }
    }
  }

  Future<void> _chooseRange() async {
    final value = await chooseReportRange(context, _range);
    if (mounted && value != null) setState(() => _range = value);
  }

  Future<void> _save() async {
    final id = _draftId;
    if (_saving || id == null) return;
    setState(() => _saving = true);
    try {
      await client.reportsSave(draftId: id, title: _title.text);
      if (!mounted) return;
      setState(() => _draftId = null);
      if (widget.tab == 2) await _loadLibrary();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr('Report saved'))));
      }
    } catch (e) {
      if (mounted) setState(() => _topicError = _code(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _open(int id) async {
    try {
      final result = await client.reportsGet(id: id);
      if (mounted) {
        setState(() {
          _opened = result['report'] as Map<String, dynamic>;
          _libraryError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _libraryError = _code(e));
    }
  }

  Future<void> _edit(Map<String, dynamic> report) async {
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _ReportEditDialog(tr: tr, report: report),
    );
    if (result == null || !mounted) return;
    try {
      final reply = await client.reportsUpdate(
        id: report['id'] as int,
        title: result.$1,
        note: result.$2,
      );
      if (!mounted) return;
      setState(() => _opened = reply['report'] as Map<String, dynamic>);
      await _loadLibrary();
    } catch (e) {
      if (mounted) setState(() => _libraryError = _code(e));
    }
  }

  Future<void> _delete(int id) async {
    if (!await _confirm('Delete this report?', 'Delete') || !mounted) return;
    try {
      await client.reportsDelete(id: id);
      if (!mounted) return;
      setState(() => _opened = null);
      await _loadLibrary();
    } catch (e) {
      if (mounted) setState(() => _libraryError = _code(e));
    }
  }

  Future<void> _moveAside() async {
    if (!await _confirm(
          'Move the damaged library aside?',
          'Move aside and start new',
        ) ||
        !mounted) {
      return;
    }
    try {
      await client.reportsMoveAside();
      if (!mounted) return;
      setState(() => _opened = null);
      await _loadLibrary();
    } catch (e) {
      if (mounted) setState(() => _libraryError = _code(e));
    }
  }

  Widget _error(String code) => Text(
    tr(switch (code) {
      'no_helper' => 'No report helper is available.',
      'online_blocked' => 'Online helpers are off for activity reports.',
      'no_entries' => 'No entries match the report filters.',
      'log_off' => 'Turn on the activity log to collect entries.',
      'helper_failed' => 'The report helper failed.',
      'bad_answer' => 'The helper returned an invalid report.',
      'draft_unknown' => 'This draft has expired.',
      'reports_db_corrupt' => 'The report library is damaged.',
      'reports_db_locked' => 'The report library is busy.',
      'reports_db_unavailable' => 'The report library is unavailable.',
      'reports_db_read_only' =>
        'This library was created by a newer Maprisma version.',
      'report_not_found' => 'The report could not be found.',
      _ => 'The report operation failed.',
    }),
    style: TextStyle(color: Theme.of(context).colorScheme.error),
  );

  @override
  Widget build(BuildContext context) {
    final range = _range;
    final draft = _draft;
    final opened = _opened;
    final enabled = widget.settings['ai_activity_log'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WindowHeader(
          title: tr('Reports'),
          tr: tr,
          onBack: widget.onBack,
          actions: [
            IconButton(
              key: const ValueKey('reports-help'),
              tooltip: tr('How reporting works (F1)'),
              onPressed: showHelp,
              icon: const Icon(Icons.help_outline),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Wrap(
            spacing: AppSpace.sm,
            children: [
              for (final (i, label) in [
                'Log',
                'Topic reports',
                'Library',
              ].indexed)
                ChoiceChip(
                  label: Text(tr(label)),
                  selected: widget.tab == i,
                  onSelected: (_) => widget.onTab(i),
                ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: IndexedStack(
            index: widget.tab,
            children: [
              _scroll('log', [
                _settings(),
                _historyStatus(),
                if (!enabled)
                  Text(tr('Turn on the activity log to collect entries.')),
                if (enabled)
                  ActivityLogPane(
                    key: _log,
                    client: client,
                    tr: tr,
                    active: widget.tab == 0 && widget.active,
                  ),
              ]),
              _scroll('topics', [
                SectionCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: AppSpace.sm,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _running ? null : _chooseRange,
                            icon: const Icon(Icons.date_range),
                            label: Text(
                              range == null
                                  ? tr('Date range')
                                  : '${reportDay(range.start)} – ${reportDay(range.end)}',
                            ),
                          ),
                          if (range != null)
                            IconButton(
                              tooltip: tr('Clear'),
                              onPressed: _running
                                  ? null
                                  : () => setState(() => _range = null),
                              icon: const Icon(Icons.clear),
                            ),
                        ],
                      ),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final filters = [
                            _field(
                              _project,
                              'Project filter',
                              enabled: !_running,
                              limit: 64,
                            ),
                            _field(
                              _source,
                              'Agent or runtime filter',
                              enabled: !_running,
                              limit: 130,
                            ),
                          ];
                          return constraints.maxWidth < 560
                              ? Column(children: filters)
                              : Row(
                                  children: [
                                    Expanded(child: filters.first),
                                    const SizedBox(width: AppSpace.md),
                                    Expanded(child: filters.last),
                                  ],
                                );
                        },
                      ),
                      _field(
                        _focus,
                        'Report focus',
                        enabled: !_running,
                        limit: 500,
                      ),
                      const SizedBox(height: AppSpace.sm),
                      DropdownButtonFormField<String>(
                        key: ValueKey('report-helper-$_helper'),
                        initialValue: _helper,
                        isExpanded: true,
                        decoration: InputDecoration(labelText: tr('Helper')),
                        items: [
                          for (final helper
                              in _helpers?['helpers'] as List? ?? [])
                            DropdownMenuItem(
                              value: helper['command'] as String,
                              child: Text(
                                '${helper['name']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _running
                            ? null
                            : (value) => setState(() => _helper = value),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      if (_helpers?['rules_broken'] == true)
                        Text(tr('Ask AI rules could not be read.'))
                      else if (_helpers?['online_allowed'] == false)
                        Text(
                          tr('Online helpers are off for activity reports.'),
                        ),
                      if (_helpers != null && _helper == null)
                        Text(tr('No report helper is available.')),
                    ],
                  ),
                ),
                if (_running) ...[
                  const LinearProgressIndicator(),
                  Text(tr('Generating report…')),
                ],
                if (_topicError case final String error) _error(error),
                if (draft != null) ...[
                  _field(_title, 'Title', limit: 200),
                  if (draft['capped'] == true)
                    Text(
                      tr('Only part of the matching log fit in this report.'),
                    ),
                  ReportOutput(report: draft, tr: tr, showTitle: false),
                ],
              ]),
              _scroll('library', [
                if (_library?['read_only'] == true)
                  _error('reports_db_read_only'),
                if (_libraryError case final String error) _error(error),
                if (opened == null) ...[
                  TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      labelText: tr('Search reports'),
                      prefixIcon: const Icon(Icons.search),
                    ),
                    onChanged: (_) {
                      _searchTimer?.cancel();
                      _searchTimer = Timer(
                        const Duration(milliseconds: 250),
                        _loadLibrary,
                      );
                    },
                    onSubmitted: (_) {
                      _searchTimer?.cancel();
                      _loadLibrary();
                    },
                  ),
                  if (_libraryLoading) const LinearProgressIndicator(),
                  if (_library?['reports'] case final List rows)
                    if (rows.isEmpty)
                      Text(tr('No saved reports.'))
                    else
                      SectionCard(
                        child: Column(
                          children: [
                            for (final row in rows)
                              ListTile(
                                leading: const Icon(Icons.description_outlined),
                                title: Text('${row['title']}'),
                                subtitle: Text(
                                  "${row['from_day']} – ${row['through_day']}  ·  ${row['saved_at'].toString().split('T').first}",
                                ),
                                onTap: () => _open(row['id'] as int),
                              ),
                          ],
                        ),
                      ),
                ] else ...[
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _opened = null),
                      icon: const Icon(Icons.arrow_back),
                      label: Text(tr('Library')),
                    ),
                  ),
                  ReportOutput(report: opened, tr: tr),
                ],
              ]),
            ],
          ),
        ),
        if (widget.tab == 1)
          WindowFooter(
            children: [
              if (draft != null)
                ...reportExportButtons(context, {
                  ...draft,
                  'title': _title.text,
                }, tr),
              if (_running)
                TextButton(
                  onPressed: allowExit,
                  child: Text(tr('Cancel report')),
                ),
              if (_draftId != null)
                FilledButton(
                  onPressed: _saving || _title.text.trim().isEmpty
                      ? null
                      : _save,
                  child: Text(tr('Save to library')),
                ),
              if (_draftId != null)
                OutlinedButton(
                  onPressed: _running || _saving || _helper == null
                      ? null
                      : _generate,
                  child: Text(tr('Generate')),
                )
              else
                FilledButton(
                  onPressed: _running || _saving || _helper == null
                      ? null
                      : _generate,
                  child: Text(tr('Generate')),
                ),
            ],
          )
        else if (widget.tab == 2)
          WindowFooter(
            children: [
              if (_libraryError == 'reports_db_corrupt')
                OutlinedButton(
                  onPressed: _moveAside,
                  child: Text(tr('Move aside and start new')),
                ),
              if (opened != null) ...[
                ...reportExportButtons(context, opened, tr),
                if (_library?['read_only'] != true) ...[
                  TextButton(
                    onPressed: () => _delete(opened['id'] as int),
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                    child: Text(tr('Delete')),
                  ),
                  OutlinedButton(
                    onPressed: () => _edit(opened),
                    child: Text(tr('Edit title and note')),
                  ),
                ],
              ] else ...[
                TextButton(
                  onPressed: _libraryLoading ? null : _loadLibrary,
                  child: Text(tr('Refresh')),
                ),
                if (_library?['next_cursor'] case final int cursor)
                  OutlinedButton(
                    onPressed: _libraryLoading
                        ? null
                        : () => _loadLibrary(cursor: cursor),
                    child: Text(tr('Next')),
                  ),
              ],
            ],
          ),
      ],
    );
  }

  Widget _scroll(String key, List<Widget> children) => SingleChildScrollView(
    key: PageStorageKey('reports-$key'),
    padding: const EdgeInsets.all(AppSpace.lg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i != 0) const SizedBox(height: AppSpace.lg),
          child,
        ],
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    bool enabled = true,
    int? limit,
  }) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.sm),
    child: TextField(
      controller: controller,
      focusNode: controller == _focus ? _focusNode : null,
      enabled: enabled,
      maxLength: limit,
      decoration: InputDecoration(
        labelText: tr(label),
        counterText: '',
        helperText: controller == _focus && _partialFocus.isNotEmpty
            ? _partialFocus
            : null,
        suffixIcon: controller == _focus && widget.tab == 1
            ? MicButton(
                appId: 'com.maprisma.Maprisma',
                tr: tr,
                controller: controller,
                onFinal: (text) {
                  insertDictatedText(controller, text);
                  final bounded = String.fromCharCodes(
                    controller.text.runes.take(500),
                  );
                  if (bounded != controller.text) {
                    controller.value = TextEditingValue(
                      text: bounded,
                      selection: TextSelection.collapsed(
                        offset: bounded.length,
                      ),
                    );
                  }
                },
                focusNode: _focusNode,
                enabled: enabled,
                onPartial: (value) {
                  if (mounted && widget.tab == 1) {
                    setState(() => _partialFocus = value);
                  }
                },
              )
            : null,
      ),
      onChanged: controller == _title ? (_) => setState(() {}) : null,
    ),
  );

  Widget _settings() {
    final settings = widget.settings;
    final days = settings['ai_activity_log_days'] as int? ?? 7;
    return SectionCard(
      title: tr('Settings'),
      child: Column(
        children: [
          SettingRow(
            title: tr('AI activity log'),
            control: Switch(
              value: settings['ai_activity_log'] == true,
              onChanged: (value) => _update('ai_activity_log', value),
            ),
          ),
          SettingRow(
            title: tr('Keep log for (days)'),
            control: DropdownButton<int>(
              value: days,
              items: [
                for (final value in ({
                  1,
                  2,
                  7,
                  30,
                  90,
                  365,
                  days,
                }.toList()..sort()))
                  DropdownMenuItem(
                    value: value,
                    child: Text(
                      value == 7 ? '$value · ${tr('Default')}' : '$value',
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) _update('ai_activity_log_days', value);
              },
            ),
          ),
          SettingRow(
            title: tr('Collect activity from agent history'),
            control: Switch(
              value: settings['ai_activity_import'] != false,
              onChanged: (value) => _update('ai_activity_import', value),
            ),
          ),
          SettingRow(
            title: tr("Use the agent's request as topic"),
            control: Switch(
              value: settings['ai_activity_import_topics'] != false,
              onChanged: settings['ai_activity_import'] == false
                  ? null
                  : (value) => _update('ai_activity_import_topics', value),
            ),
          ),
          SettingRow(
            title: tr('Topic summaries by local LLM'),
            subtitle: widget.localHelperReady
                ? null
                : tr('No report helper is available.'),
            control: Switch(
              value: settings['ai_activity_local_topics'] == true,
              onChanged: widget.localHelperReady
                  ? (value) => _update('ai_activity_local_topics', value)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _update(String key, Object value) async {
    await widget.onUpdate({key: value});
    if (mounted) _log.currentState?.refresh();
  }
}

class _ReportEditDialog extends StatefulWidget {
  const _ReportEditDialog({required this.tr, required this.report});
  final String Function(String) tr;
  final Map<String, dynamic> report;

  @override
  State<_ReportEditDialog> createState() => _ReportEditDialogState();
}

class _ReportEditDialogState extends State<_ReportEditDialog> {
  late final _title = TextEditingController(
    text: widget.report['title'] as String,
  );
  late final _note = TextEditingController(
    text: widget.report['note'] as String?,
  );

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.tr('Edit title and note')),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _title,
          onChanged: (_) => setState(() {}),
          maxLength: 200,
          decoration: InputDecoration(labelText: widget.tr('Title')),
        ),
        TextField(
          controller: _note,
          maxLength: 2000,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(labelText: widget.tr('Note')),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.tr('Cancel')),
      ),
      FilledButton(
        onPressed: _title.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, (_title.text, _note.text)),
        child: Text(widget.tr('Save')),
      ),
    ],
  );
}
