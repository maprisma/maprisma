import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:maprisma_core/maprisma_core.dart' show ServiceError;
import 'core_client.g.dart';

/// Shared by the startup run and Reports so opening the page shows the same job.
class HistoryImportController extends ChangeNotifier {
  bool running = false;
  bool _disposed = false;
  bool _autoAttempted = false;
  String progress = '';
  String? error;
  Map<String, dynamic>? result;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> collect(CoreClient client, {bool auto = false}) async {
    if (running || _disposed || auto && _autoAttempted) return;
    if (auto) _autoAttempted = true;
    running = true;
    error = null;
    progress = '';
    _changed();
    try {
      final started = await client.activitylogImport(auto: auto);
      final task = started['task'];
      if (task is! String) return;
      while (!_disposed) {
        final state = await client.tasksStatus(task: task);
        if (_disposed) return;
        progress = '${state['text'] ?? ''}';
        _changed();
        if (state['state'] != 'running') {
          if (state['state'] == 'done') {
            final value = (state['result'] as Map? ?? {})
                .cast<String, dynamic>();
            if (value['code'] is String) {
              if (!auto) error = value['code'] as String;
            } else if (value['sources'] is List) {
              result = value;
            }
          } else if (!auto) {
            error = 'operation_failed';
          }
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      if (!auto) error = e is ServiceError ? e.code : 'operation_failed';
    } finally {
      running = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
