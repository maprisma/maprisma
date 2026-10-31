import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart' show corners;
import 'connections_view.dart' show ConnectionReview;
import 'model_removal_dialog.dart';
import 'core_client.g.dart';
import 'providers_view.dart' show modelSize;
import 'task_card.dart' show TaskReview;

const mapSmartColumns = [
  ('mcp', 'MCP servers and skills'),
  ('agents', 'Agents'),
  ('providers', 'Providers'),
  ('models', 'Models'),
];

String _columnHint(String column) => switch (column) {
  'mcp' => 'Find an MCP server or skill…',
  'agents' => 'Set up or connect an agent…',
  'providers' => 'Set up or tune a provider…',
  'models' => 'Find or connect a model…',
  _ => 'Ask for this column…',
};

String smartFitLabel(String? fit, String Function(String) tr) => switch (fit) {
  'ok' => tr('Fits in VRAM'),
  'tight' => tr('Uses RAM offload'),
  'too_large' => tr('Too large for this PC'),
  _ => '',
};

class SmartModelDownloadReview extends StatelessWidget {
  const SmartModelDownloadReview({
    super.key,
    required this.review,
    required this.tr,
    required this.onConfirm,
    required this.onCancel,
  });

  final Map<String, dynamic> review;
  final String Function(String) tr;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final title = '${review['title'] ?? ''}';
    final subtitle = '${review['subtitle'] ?? ''}';
    final runtime = '${review['runtime'] ?? ''}';
    final size = modelSize(review['size'] as int? ?? 0);
    final fit = smartFitLabel(review['fit'] as String?, tr);
    return TaskReview(
      title: Text(
        tr('Download {0}?').replaceAll('{0}', title),
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(subtitle, style: const TextStyle(fontSize: 12)),
            ),
          if (runtime.isNotEmpty)
            Text(
              '${tr('Runtime')}: $runtime',
              style: const TextStyle(fontSize: 12),
            ),
          Text(
            '${tr('Download')}: $size',
            style: const TextStyle(fontSize: 12),
          ),
          if (fit.isNotEmpty)
            Text(
              '${tr('This PC')}: $fit',
              style: const TextStyle(fontSize: 12),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: onCancel, child: Text(tr('Cancel'))),
        FilledButton(onPressed: onConfirm, child: Text(tr('Download'))),
      ],
    );
  }
}

enum _SmartStep {
  idle,
  working,
  clarify,
  redirect,
  proposal,
  review,
  running,
  done,
  connectReview,
  mcpForm,
  error,
}

class MapSmartCard extends StatefulWidget {
  const MapSmartCard({
    super.key,
    this.takesRequests = true,
    required this.column,
    required this.title,
    required this.open,
    this.enabled = true,
    required this.onToggle,
    required this.tr,
    this.helpers = const [],
    this.client,
    this.initialPrompt,
    this.onMoveToColumn,
    this.onApplied,
    this.width = 266,
  });

  /// A column whose helper is not built yet says so before anyone types.
  final bool takesRequests;
  final String column;
  final String title;
  final bool open;
  final bool enabled;
  final VoidCallback onToggle;
  final String Function(String) tr;
  final List<Map<String, dynamic>> helpers;
  final CoreClient? client;
  final String? initialPrompt;
  final void Function(String column, String request)? onMoveToColumn;
  final ValueChanged<Map<String, dynamic>>? onApplied;
  final double width;

  @override
  State<MapSmartCard> createState() => _MapSmartCardState();
}

class _MapSmartCardState extends State<MapSmartCard> {
  final _prompt = TextEditingController();
  final _barFocus = FocusNode();
  final _cardFocus = FocusNode();
  final _fieldFocus = FocusNode();
  String? _selectedCommand;
  _SmartStep _step = _SmartStep.idle;
  String? _activeTask;
  int _runToken = 0;
  Map<String, dynamic> _reply = const {};
  String? _activeProposal;
  Map<String, dynamic>? _activeCandidate;
  Set<String> _mcpAgents = {};
  final _mcpFields = <String, TextEditingController>{};
  Map<String, dynamic> _reviewData = const {};
  Map<String, dynamic> _connectPlan = const {};
  double? _runFraction;
  String _runText = '';
  String _errorText = '';
  _SmartStep _errorReturnTo = _SmartStep.idle;

  Map<String, dynamic>? get _activeHelper {
    if (widget.helpers.isEmpty) return null;
    if (_selectedCommand != null) {
      for (final h in widget.helpers) {
        if (h['command'] == _selectedCommand) return h;
      }
    }
    return widget.helpers.first;
  }

  void _focusOpenCard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.open) return;
      if (_step == _SmartStep.idle) {
        _fieldFocus.requestFocus();
      } else if (!_cardFocus.hasFocus) {
        _cardFocus.requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      _prompt.text = widget.initialPrompt!;
    }
    if (widget.open) {
      _focusOpenCard();
    }
  }

  @override
  void didUpdateWidget(covariant MapSmartCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialPrompt != null &&
        widget.initialPrompt != oldWidget.initialPrompt &&
        widget.initialPrompt!.isNotEmpty) {
      _prompt.text = widget.initialPrompt!;
      _step = _SmartStep.idle;
    }
    if (oldWidget.enabled && !widget.enabled && _step == _SmartStep.working) {
      _abortWorking();
    }
    if (!oldWidget.open && widget.open) {
      _focusOpenCard();
    } else if (oldWidget.open && !widget.open) {
      if (_step == _SmartStep.redirect) _step = _SmartStep.idle;
    }
  }

  void _abortWorking() {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    _step = _SmartStep.idle;
    _errorText = '';
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
    }
  }

  void _close() {
    if (_step == _SmartStep.working) {
      setState(_abortWorking);
    } else if (_step != _SmartStep.running) {
      _runToken++;
      final taskId = _activeTask;
      _activeTask = null;
      if (taskId != null && widget.client != null) {
        unawaited(
          widget.client!
              .tasksCancel(task: taskId)
              .then((_) {}, onError: (_) {}),
        );
      }
    }
    widget.onToggle();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.open) _barFocus.requestFocus();
    });
  }

  void _backToIdle() {
    setState(() {
      _step = _SmartStep.idle;
      _errorText = '';
      _errorReturnTo = _SmartStep.idle;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open && _step == _SmartStep.idle) {
        _fieldFocus.requestFocus();
      }
    });
  }

  void _tryAgain() {
    if (_errorReturnTo == _SmartStep.proposal &&
        _reply['status'] == 'proposal') {
      setState(() {
        _errorText = '';
        _step = _SmartStep.proposal;
      });
    } else {
      _backToIdle();
    }
  }

  void _cancelTask({_SmartStep returnTo = _SmartStep.idle}) {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
    }
    if (returnTo == _SmartStep.idle) {
      _backToIdle();
    } else {
      setState(() => _step = returnTo);
    }
  }

  Future<void> _ask({String? answer}) async {
    final request = _prompt.text.trim();
    final helper = _activeHelper;
    final client = widget.client;
    if (request.isEmpty || helper == null || client == null) return;
    final token = ++_runToken;
    setState(() {
      _step = _SmartStep.working;
      _activeTask = null;
      _errorText = '';
      _errorReturnTo = _SmartStep.idle;
    });
    _focusOpenCard();
    try {
      final started = await client.mapSmartAsk(
        column: widget.column,
        command: '${helper['command']}',
        request: request,
        answer: answer,
      );
      if (!mounted || token != _runToken) return;
      final taskId = started['task'] as String?;
      if (taskId == null || taskId.isEmpty) {
        setState(() {
          _errorText = widget.tr('The action could not be completed.');
          _step = _SmartStep.error;
        });
        return;
      }
      _activeTask = taskId;
      while (mounted && token == _runToken) {
        final status = await client.tasksStatus(task: taskId);
        if (!mounted || token != _runToken) return;
        final state = status['state'] as String?;
        if (state == 'done') {
          _activeTask = null;
          final result =
              (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          setState(() {
            _reply = result;
            switch (result['status']) {
              case 'clarify':
                _step = _SmartStep.clarify;
              case 'redirect':
                _step = _SmartStep.redirect;
              case 'proposal':
                _step = _SmartStep.proposal;
              default:
                _errorText =
                    '${result['summary'] ?? widget.tr('The action could not be completed.')}';
                _step = _SmartStep.error;
            }
          });
          return;
        }
        if (state == 'stopped') {
          _activeTask = null;
          _backToIdle();
          return;
        }
        if (state != 'running') {
          _activeTask = null;
          setState(() {
            _errorText = widget.tr('The action could not be completed.');
            _step = _SmartStep.error;
          });
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  /// An MCP candidate: the form when something is to choose or fill in, else
  /// the normal review at once.
  void _openMcp(String proposal, Map<String, dynamic> candidate) {
    _activeProposal = proposal;
    _activeCandidate = candidate;
    if (candidate['kind'] != 'mcp_add') {
      unawaited(
        _planMcp([
          for (final a in candidate['agents'] as List? ?? const []) '$a',
        ]),
      );
      return;
    }
    for (final field in _mcpFields.values) {
      field.dispose();
    }
    _mcpFields.clear();
    for (final need in (candidate['needs'] as List? ?? const []).cast<Map>()) {
      _mcpFields['${need['name']}'] = TextEditingController(
        text: '${need['value'] ?? ''}',
      );
    }
    setState(() {
      _mcpAgents = {
        for (final a in candidate['agents'] as List? ?? const []) '$a',
      };
      _step = _SmartStep.mcpForm;
    });
  }

  Future<void> _planMcp(List<String> agents) async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    try {
      final plan = await client.mapSmartPlan(
        proposal: proposal,
        candidate: '${candidate['id']}',
        agents: agents,
        values: {for (final e in _mcpFields.entries) e.key: e.value.text},
      );
      if (!mounted || token != _runToken) return;
      setState(() {
        _connectPlan = plan;
        _step = _SmartStep.connectReview;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  Widget _buildMcpForm(ColorScheme colors) {
    final candidate = _activeCandidate ?? const {};
    final agents = (_reply['agents'] as List? ?? const []).cast<Map>();
    final needs = (candidate['needs'] as List? ?? const []).cast<Map>();
    final ready =
        _mcpAgents.isNotEmpty &&
        _mcpFields.values.every((f) => f.text.trim().isNotEmpty);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${candidate['title'] ?? ''}',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          widget.tr('Connect it to these agents'),
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final agent in agents)
              FilterChip(
                key: ValueKey('smart-mcp-agent-${agent['command']}'),
                visualDensity: VisualDensity.compact,
                label: Text('${agent['name']}'),
                selected: _mcpAgents.contains('${agent['command']}'),
                onSelected: (on) => setState(() {
                  on
                      ? _mcpAgents.add('${agent['command']}')
                      : _mcpAgents.remove('${agent['command']}');
                }),
              ),
          ],
        ),
        for (final need in needs) ...[
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('smart-mcp-need-${need['name']}'),
            controller: _mcpFields['${need['name']}'],
            obscureText: need['secret'] == true,
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              labelText: '${need['name']}',
              helperText: '${need['description'] ?? ''}'.isEmpty
                  ? null
                  : '${need['description']}',
              helperMaxLines: 2,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 6,
          children: [
            TextButton(
              onPressed: () => setState(() => _step = _SmartStep.proposal),
              child: Text(widget.tr('← Back')),
            ),
            FilledButton(
              key: const ValueKey('smart-mcp-review'),
              onPressed: ready ? () => _planMcp(_mcpAgents.toList()) : null,
              child: Text(widget.tr('Review')),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _openReview(
    String proposal,
    Map<String, dynamic> candidate,
  ) async {
    final client = widget.client;
    if (client == null) return;
    final token = ++_runToken;
    try {
      final review = await client.mapSmartReview(
        proposal: proposal,
        candidate: '${candidate['id']}',
      );
      if (!mounted || token != _runToken) return;
      setState(() {
        _activeProposal = proposal;
        _activeCandidate = candidate;
        _reviewData = review;
        _step = _SmartStep.review;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  Future<void> _confirmReview() async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    setState(() {
      _step = _SmartStep.running;
      _activeTask = null;
      _runFraction = null;
      _runText = '${candidate['title'] ?? ''}';
      _errorReturnTo = _SmartStep.proposal;
    });
    _focusOpenCard();
    try {
      final started = await client.mapSmartRun(
        proposal: proposal,
        candidate: '${candidate['id']}',
      );
      if (!mounted || token != _runToken) return;
      final taskId = started['task'] as String?;
      if (taskId == null || taskId.isEmpty) {
        setState(() {
          _errorText = widget.tr('The action could not be completed.');
          _step = _SmartStep.error;
        });
        return;
      }
      _activeTask = taskId;
      while (mounted && token == _runToken) {
        final status = await client.tasksStatus(task: taskId);
        if (!mounted || token != _runToken) return;
        final state = status['state'] as String?;
        if (state == 'done') {
          _activeTask = null;
          final result =
              (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
          if (result['ok'] == false) {
            setState(() {
              _errorText =
                  '${result['message'] ?? widget.tr('The action could not be completed.')}';
              _step = _SmartStep.error;
            });
            return;
          }
          widget.onApplied?.call(result);
          if (candidate['kind'] == 'model_remove') {
            setState(() => _step = _SmartStep.idle);
            _close();
            return;
          }
          setState(() => _step = _SmartStep.done);
          return;
        }
        if (state == 'stopped') {
          _activeTask = null;
          setState(() => _step = _SmartStep.proposal);
          return;
        }
        if (state != 'running') {
          _activeTask = null;
          setState(() {
            _errorText = widget.tr('The action could not be completed.');
            _step = _SmartStep.error;
          });
          return;
        }
        setState(() {
          _runFraction = (status['fraction'] as num?)?.toDouble();
          final text = '${status['text'] ?? ''}';
          if (text.isNotEmpty) _runText = text;
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (!mounted || token != _runToken) return;
      _activeTask = null;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  Future<void> _openConnect(String agentCommand) async {
    final client = widget.client;
    final proposal = _activeProposal;
    final candidate = _activeCandidate;
    if (client == null || proposal == null || candidate == null) return;
    final token = ++_runToken;
    try {
      final plan = await client.mapSmartConnect(
        proposal: proposal,
        candidate: '${candidate['id']}',
        agent: agentCommand,
      );
      if (!mounted || token != _runToken) return;
      setState(() {
        _connectPlan = plan;
        _step = _SmartStep.connectReview;
      });
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  Future<void> _applyConnect() async {
    final client = widget.client;
    final planToken = _connectPlan['plan'] as String?;
    if (client == null || planToken == null) return;
    final token = ++_runToken;
    try {
      var result = await client.connectionsApply(plan: planToken);
      if (!mounted || token != _runToken) return;
      final taskId = result['task'] as String?;
      if (taskId != null && taskId.isNotEmpty) {
        _activeTask = taskId;
        while (mounted && token == _runToken) {
          final status = await client.tasksStatus(task: taskId);
          if (!mounted || token != _runToken) return;
          if (status['state'] == 'done') {
            _activeTask = null;
            result =
                (status['result'] as Map?)?.cast<String, dynamic>() ?? const {};
            break;
          }
          if (status['state'] != 'running') {
            _activeTask = null;
            setState(() {
              _errorText = widget.tr('The action could not be completed.');
              _step = _SmartStep.error;
            });
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      widget.onApplied?.call(result);
      setState(() => _step = _SmartStep.idle);
      _close();
    } catch (_) {
      if (!mounted || token != _runToken) return;
      setState(() {
        _errorText = widget.tr('The action could not be completed.');
        _step = _SmartStep.error;
      });
    }
  }

  @override
  void dispose() {
    _runToken++;
    _prompt.dispose();
    for (final field in _mcpFields.values) {
      field.dispose();
    }
    _barFocus.dispose();
    _cardFocus.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  List<Widget> _buildHelperLine(ColorScheme colors) {
    final helper = _activeHelper;
    if (helper == null) return const [];
    final cost = widget.tr(
      helper['local'] == true ? 'Local, no tokens' : 'Uses plan/tokens',
    );
    return [
      Row(
        children: [
          Expanded(
            child: widget.helpers.length > 1
                ? DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      key: const ValueKey('smart-helper-select'),
                      isExpanded: true,
                      isDense: true,
                      value: '${helper['command']}',
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _selectedCommand = value);
                        }
                      },
                      items: [
                        for (final h in widget.helpers)
                          DropdownMenuItem<String>(
                            value: '${h['command']}',
                            child: Text(
                              '${h['name']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  )
                : Text(
                    '${helper['name']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              cost,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
    ];
  }

  Widget _buildIdle(ColorScheme colors) => !widget.takesRequests
      ? Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.tr('This column does not take requests yet.'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _close,
                child: Text(widget.tr('Close')),
              ),
            ),
          ],
        )
      : _buildAsk(colors);

  Widget _buildAsk(ColorScheme colors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ..._buildHelperLine(colors),
      TextField(
        controller: _prompt,
        focusNode: _fieldFocus,
        autofocus: true,
        minLines: 2,
        maxLines: 3,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.tr(_columnHint(widget.column)),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 6,
        children: [
          TextButton(onPressed: _close, child: Text(widget.tr('Close'))),
          FilledButton(onPressed: () => _ask(), child: Text(widget.tr('Ask'))),
        ],
      ),
    ],
  );

  Widget _buildWorking() {
    final helperName = '${_activeHelper?['name'] ?? ''}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _prompt.text.trim(),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Text(
          widget
              .tr('{0} is checking {1}…')
              .replaceAll('{0}', helperName)
              .replaceAll('{1}', widget.tr(widget.title)),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _cancelTask,
            child: Text(widget.tr('Cancel')),
          ),
        ),
      ],
    );
  }

  Widget _buildClarify(ColorScheme colors) {
    final question = '${_reply['question'] ?? ''}';
    final choices = (_reply['choices'] as List? ?? const [])
        .map((c) => '$c')
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          question,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        ..._buildHelperLine(colors),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final choice in choices)
              ActionChip(
                label: Text(choice, style: const TextStyle(fontSize: 12)),
                onPressed: () => _ask(answer: choice),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 6,
          children: [
            TextButton(
              onPressed: _backToIdle,
              child: Text(widget.tr('← Back')),
            ),
            TextButton(onPressed: _close, child: Text(widget.tr('Close'))),
          ],
        ),
      ],
    );
  }

  Widget _buildRedirect() {
    final instead =
        (_reply['instead'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hint = '${instead['hint'] ?? ''}';
    final targetCol = instead['column'] as String?;
    final targetTitle = mapSmartColumns
        .where((c) => c.$1 == targetCol)
        .firstOrNull
        ?.$2;
    final targetReq = instead['request'] as String?;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(hint, style: const TextStyle(fontSize: 12)),
        if (targetCol != null &&
            targetTitle != null &&
            targetCol != widget.column) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: () {
                final req = (targetReq != null && targetReq.isNotEmpty)
                    ? targetReq
                    : _prompt.text.trim();
                widget.onMoveToColumn?.call(targetCol, req);
              },
              child: Text(
                widget
                    .tr('Move to {0}')
                    .replaceAll('{0}', widget.tr(targetTitle)),
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 6,
          children: [
            TextButton(
              onPressed: _backToIdle,
              child: Text(widget.tr('← Back')),
            ),
            TextButton(onPressed: _close, child: Text(widget.tr('Close'))),
          ],
        ),
      ],
    );
  }

  Widget _buildProposal(ColorScheme colors) {
    final summary = '${_reply['summary'] ?? ''}';
    final proposal = _reply['proposal'] as String?;
    final limits =
        (_reply['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final candidates = (_reply['candidates'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final vram = limits['vram'] as int?;
    final ram = limits['ram'] as int?;
    final freeDisk = limits['free_disk'] as int?;
    final limitsLine = (ram != null || freeDisk != null)
        ? (vram != null && vram > 0
              ? widget
                    .tr('PC: {0} VRAM · {1} RAM · {2} free')
                    .replaceAll('{0}', modelSize(vram))
                    .replaceAll('{1}', modelSize(ram ?? 0))
                    .replaceAll('{2}', modelSize(freeDisk ?? 0))
              : widget
                    .tr('PC: {0} RAM · {1} free')
                    .replaceAll('{0}', modelSize(ram ?? 0))
                    .replaceAll('{1}', modelSize(freeDisk ?? 0)))
        : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.isNotEmpty) ...[
          Text(summary, style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
        ],
        if (limitsLine.isNotEmpty) ...[
          Text(
            limitsLine,
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        for (final c in candidates)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: colors.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (c['size'] as int? ?? 0) > 0
                          ? '${c['title']} · ${modelSize(c['size'] as int)}'
                          : '${c['title']}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if ('${c['subtitle'] ?? ''}'.isNotEmpty)
                      Text(
                        '${c['subtitle']}',
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (smartFitLabel(
                      c['fit'] as String?,
                      widget.tr,
                    ).isNotEmpty)
                      Text(
                        smartFitLabel(c['fit'] as String?, widget.tr),
                        style: TextStyle(
                          fontSize: 11,
                          color: c['fit'] == 'too_large'
                              ? colors.error
                              : colors.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if ('${c['reason'] ?? ''}'.isNotEmpty)
                      Text(
                        '${c['reason']}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    if (c['fit'] != 'too_large' && proposal != null) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          key: ValueKey('smart-review-${c['id']}'),
                          onPressed: () =>
                              '${c['kind'] ?? ''}'.startsWith('mcp_')
                              ? _openMcp(proposal, c)
                              : _openReview(proposal, c),
                          child: Text(widget.tr('Review')),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 6,
          children: [
            TextButton(
              onPressed: _backToIdle,
              child: Text(widget.tr('← Back')),
            ),
            TextButton(onPressed: _close, child: Text(widget.tr('Close'))),
          ],
        ),
      ],
    );
  }

  Widget _buildRunning() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        '${_activeCandidate?['title'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: _runFraction),
      const SizedBox(height: 8),
      if (_runText.isNotEmpty)
        Text(_runText, style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: () => _cancelTask(returnTo: _SmartStep.proposal),
          child: Text(widget.tr('Cancel')),
        ),
      ),
    ],
  );

  Widget _buildDone() {
    final title = '${_activeCandidate?['title'] ?? ''}';
    final connectAgents = [
      for (final h in widget.helpers)
        if (h['command'] != 'local-helper') h,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.tr('{0} is ready.').replaceAll('{0}', title),
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        if (connectAgents.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            widget.tr('Connect it to an agent now? (Optional)'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final agent in connectAgents)
                ActionChip(
                  label: Text(
                    '${agent['name']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: () => _openConnect('${agent['command']}'),
                ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 6,
          children: [
            FilledButton.tonal(
              onPressed: () {
                _step = _SmartStep.idle;
                _close();
              },
              child: Text(widget.tr('Done')),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildError(ColorScheme colors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(_errorText, style: TextStyle(fontSize: 12, color: colors.error)),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 6,
        children: [
          TextButton(onPressed: _close, child: Text(widget.tr('Close'))),
          FilledButton.tonal(
            onPressed: _tryAgain,
            child: Text(widget.tr('Try again')),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(corners(context));
    final helper = _activeHelper;
    if (!widget.open) {
      return SizedBox(
        width: widget.width,
        height: 38,
        child: Semantics(
          button: true,
          toggled: false,
          label:
              '${widget.tr('Ask AI…')} · ${widget.tr(widget.title)}${helper == null ? '' : ' · ${helper['name']}'}',
          child: Material(
            color: colors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: colors.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              focusNode: _barFocus,
              onTap: widget.onToggle,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    const SizedBox(
                      key: ValueKey('smart-status-slot'),
                      width: 16,
                      height: 16,
                    ),
                    Icon(Icons.auto_awesome, size: 15, color: colors.primary),
                    const SizedBox(width: 6),
                    Text(
                      widget.tr('Ask AI…'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (helper != null)
                      Expanded(
                        child: Text(
                          ' · ${helper['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    Icon(
                      Icons.expand_more,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Focus(
      focusNode: _cardFocus,
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (_) {},
        onPanStart: (_) {},
        onPanUpdate: (_) {},
        onPanEnd: (_) {},
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: widget.width,
            maxWidth: widget.width,
            minHeight: 38,
            maxHeight: 320,
          ),
          child: Card(
            margin: EdgeInsets.zero,
            elevation: 4,
            color: colors.surfaceContainerHigh,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: colors.primary, width: 1.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: 38,
                  child: InkWell(
                    onTap: _close,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 10, right: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.auto_awesome,
                            size: 15,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              widget
                                  .tr('Ask AI · {0}')
                                  .replaceAll('{0}', widget.tr(widget.title)),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: widget.tr('Collapse'),
                            onPressed: _close,
                            icon: const Icon(Icons.expand_less, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (_step == _SmartStep.review)
                  SizedBox(
                    height: 240,
                    child: _reviewData['removal'] != null
                        ? ModelRemovalReview(
                            preview: _reviewData,
                            tr: widget.tr,
                            onConfirm: _confirmReview,
                            onCancel: () =>
                                setState(() => _step = _SmartStep.proposal),
                          )
                        : SmartModelDownloadReview(
                            review: _reviewData,
                            tr: widget.tr,
                            onConfirm: _confirmReview,
                            onCancel: () =>
                                setState(() => _step = _SmartStep.proposal),
                          ),
                  )
                else if (_step == _SmartStep.connectReview)
                  SizedBox(
                    height: 240,
                    child: ConnectionReview(
                      plan: _connectPlan,
                      tr: widget.tr,
                      onConfirm: _applyConnect,
                      onCancel: () => setState(
                        () => _step = _activeCandidate?['kind'] == null
                            ? _SmartStep.done
                            : _SmartStep.proposal,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(10),
                      child: switch (_step) {
                        _SmartStep.idle => _buildIdle(colors),
                        _SmartStep.working => _buildWorking(),
                        _SmartStep.clarify => _buildClarify(colors),
                        _SmartStep.redirect => _buildRedirect(),
                        _SmartStep.proposal => _buildProposal(colors),
                        _SmartStep.mcpForm => _buildMcpForm(colors),
                        _SmartStep.running => _buildRunning(),
                        _SmartStep.done => _buildDone(),
                        _SmartStep.error => _buildError(colors),
                        _SmartStep.review ||
                        _SmartStep.connectReview => const SizedBox.shrink(),
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
