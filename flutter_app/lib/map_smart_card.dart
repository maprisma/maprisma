import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_theme.dart' show corners;
import 'core_client.g.dart';

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

enum _SmartStep { idle, working, clarify, redirect, proposal, error }

class MapSmartCard extends StatefulWidget {
  const MapSmartCard({
    super.key,
    required this.column,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.tr,
    this.helpers = const [],
    this.client,
    this.initialPrompt,
    this.onMoveToColumn,
    this.onApplied,
  });

  final String column;
  final String title;
  final bool open;
  final VoidCallback onToggle;
  final String Function(String) tr;
  final List<Map<String, dynamic>> helpers;
  final CoreClient? client;
  final String? initialPrompt;
  final void Function(String column, String request)? onMoveToColumn;
  final ValueChanged<Map<String, dynamic>>? onApplied;

  @override
  State<MapSmartCard> createState() => _MapSmartCardState();
}

class _MapSmartCardState extends State<MapSmartCard> {
  final _prompt = TextEditingController();
  final _barFocus = FocusNode();
  final _fieldFocus = FocusNode();
  String? _selectedCommand;
  _SmartStep _step = _SmartStep.idle;
  String? _activeTask;
  int _runToken = 0;
  Map<String, dynamic> _reply = const {};
  String _errorText = '';

  Map<String, dynamic>? get _activeHelper {
    if (widget.helpers.isEmpty) return null;
    if (_selectedCommand != null) {
      for (final h in widget.helpers) {
        if (h['command'] == _selectedCommand) return h;
      }
    }
    return widget.helpers.first;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
      _prompt.text = widget.initialPrompt!;
    }
    if (widget.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.open && _step == _SmartStep.idle) {
          _fieldFocus.requestFocus();
        }
      });
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
    if (!oldWidget.open && widget.open) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.open && _step == _SmartStep.idle) {
          _fieldFocus.requestFocus();
        }
      });
    }
  }

  void _close() {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
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
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open && _step == _SmartStep.idle) {
        _fieldFocus.requestFocus();
      }
    });
  }

  void _cancelAsk() {
    _runToken++;
    final taskId = _activeTask;
    _activeTask = null;
    if (taskId != null && widget.client != null) {
      unawaited(
        widget.client!.tasksCancel(task: taskId).then((_) {}, onError: (_) {}),
      );
    }
    _backToIdle();
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
    });
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
        if (state == 'cancelled') {
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
        await Future<void>.delayed(const Duration(milliseconds: 50));
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

  @override
  void dispose() {
    _runToken++;
    _prompt.dispose();
    _barFocus.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Widget _buildIdle(ColorScheme colors) {
    final helper = _activeHelper;
    final cost = helper == null
        ? ''
        : widget.tr(
            helper['local'] == true ? 'Local, no tokens' : 'Uses plan/tokens',
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (helper != null) ...[
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
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
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
            FilledButton(
              onPressed: () => _ask(),
              child: Text(widget.tr('Ask')),
            ),
          ],
        ),
      ],
    );
  }

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
            onPressed: _cancelAsk,
            child: Text(widget.tr('Cancel')),
          ),
        ),
      ],
    );
  }

  Widget _buildClarify() {
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
                _step = _SmartStep.idle;
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
            onPressed: _backToIdle,
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
        width: 266,
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
          constraints: const BoxConstraints(
            minWidth: 266,
            maxWidth: 266,
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
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(10),
                    child: switch (_step) {
                      _SmartStep.idle => _buildIdle(colors),
                      _SmartStep.working => _buildWorking(),
                      _SmartStep.clarify => _buildClarify(),
                      _SmartStep.redirect => _buildRedirect(),
                      _SmartStep.proposal => Text(
                        '${_reply['summary'] ?? ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      _SmartStep.error => _buildError(colors),
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
