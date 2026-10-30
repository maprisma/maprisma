import 'dart:async';

import 'package:flutter/material.dart';

import 'backend.dart';

class TaskProgress extends StatefulWidget {
  const TaskProgress({
    super.key,
    required this.backend,
    required this.operation,
    required this.params,
    required this.title,
    required this.tr,
    this.existingTask,
    required this.onComplete,
    this.onFocus,
  });
  final ValueChanged<Map<String, dynamic>?> onComplete;
  final ValueChanged<Set<String>>? onFocus;
  final Backend backend;
  final String operation;
  final Map<String, dynamic> params;
  final String title;
  final String Function(String) tr;
  final String? existingTask;

  @override
  State<TaskProgress> createState() => _TaskProgressState();
}

class _TaskProgressState extends State<TaskProgress> {
  String? _task;
  double _fraction = 0;
  String _text = '';
  bool _failed = false;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final client = CoreClient(widget.backend);
    try {
      if (widget.existingTask != null) {
        _task = widget.existingTask;
      } else {
        final started = await client.providersRun(
          operation: widget.operation,
          params: widget.params,
        );
        _task = started['task'] as String;
        if (!mounted) return;
        widget.onFocus?.call(
          (started['focus'] as List? ?? []).cast<String>().toSet(),
        );
      }
      while (mounted && !_cancelling) {
        Map<String, dynamic> status;
        try {
          status = await client.tasksStatus(task: _task!);
        } catch (error) {
          if (!widget.backend.isConnected ||
              (error is BackendError && error.code == 'invalid_request')) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        if (!mounted || _cancelling) return;
        if (status['state'] == 'done') {
          widget.onComplete(status['result'] as Map<String, dynamic>);
          return;
        }
        if (status['state'] != 'running') throw StateError('Operation failed');
        setState(() {
          _fraction = (status['fraction'] as num).toDouble().clamp(0, 1);
          _text = status['text'] as String;
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        widget.onComplete({'ok': false});
      }
    }
  }

  Future<void> _cancel() async {
    if (_task == null) return;
    setState(() => _cancelling = true);
    try {
      final reply = await CoreClient(widget.backend).tasksCancel(task: _task!);
      if (mounted) {
        widget.onComplete(
          reply['state'] == 'done'
              ? reply['result'] as Map<String, dynamic>
              : null,
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _cancelling = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _failed,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_failed)
                      Text(widget.tr('The action could not be completed.'))
                    else ...[
                      LinearProgressIndicator(
                        value: _fraction > 0 ? _fraction : null,
                      ),
                      if (_text.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_text),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        Wrap(
          children: [
            if (_failed)
              TextButton(
                onPressed: () => widget.onComplete({'ok': false}),
                child: Text(widget.tr('Close')),
              )
            else if (const [
              'guide.snapshot',
              'existing.scan',
              'system.refresh',
              'system.help_apply',
              'system.move_preview',
              'system.tool_check',
              'existing.check',
              'addons.catalog',
              'models.search',
              'models.files',
              'models.download',
              'models.pull',
            ].contains(widget.operation))
              TextButton(
                onPressed: _task == null || _cancelling ? null : _cancel,
                child: Text(widget.tr('Cancel')),
              ),
          ],
        ),
      ],
    ),
  );
}
