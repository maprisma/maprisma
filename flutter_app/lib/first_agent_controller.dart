import 'dart:async';

import 'package:flutter/foundation.dart';

/// Presentation state for the existing guide read and route-selection calls.
/// A failed read never discards the last confirmed choice or checklist.
class FirstAgentController extends ChangeNotifier {
  FirstAgentController({
    required this.read,
    required this.saveChoice,
    this.abandonRead,
    this.timeout = const Duration(seconds: 90),
  });

  final Future<Map<String, dynamic>> Function() read;
  final Future<void> Function(String route) saveChoice;

  /// Stops the work behind a read whose answer is no longer wanted (timed out,
  /// replaced or left), so it does not keep running.
  final void Function()? abandonRead;

  /// A save or check that hangs ends as a failed one (Retry, and the page can be left) instead
  /// of keeping the guide busy; a late answer is ignored like any stale one.
  final Duration timeout;
  Map<String, dynamic> data = const {};
  bool loading = false;
  String? errorKey;
  String? _retryRoute;
  int _revision = 0;
  bool _disposed = false;
  bool get choiceFailed => _retryRoute != null;

  Future<void> refresh({bool replace = false}) => _load(null, replace: replace);

  Future<void> choose(String route) => _load(route);

  Future<void> retry() => _load(_retryRoute);

  Future<void> _load(String? route, {bool replace = false}) async {
    if (_disposed || loading && !replace) return;
    if (loading) abandonRead?.call();
    final revision = ++_revision;
    // Refresh after a failed save: the check runs, but the unsaved choice and its Retry stay
    // (only a new open of the guide, `replace`, starts over).
    final unsaved = route == null && !replace ? _retryRoute : null;
    loading = true;
    errorKey = null;
    _retryRoute = null;
    notifyListeners();
    var saving = route != null;
    bool current() => !_disposed && revision == _revision;
    try {
      if (route != null) {
        await saveChoice(route).timeout(timeout);
        if (!current()) return;
        data = {...data, 'selected': route};
        saving = false;
      }
      final result = await read().timeout(timeout);
      if (!current()) return;
      if (!validGuideSnapshot(result)) {
        throw const FormatException('Invalid guide snapshot');
      }
      data = result;
      if (unsaved != null) {
        _retryRoute = unsaved;
        errorKey = 'Your setup choice could not be saved. Try again.';
      }
    } catch (error) {
      if (!current()) return; // a stale read never stops the current one
      if (error is TimeoutException && !saving) abandonRead?.call();
      _retryRoute = saving ? route : unsaved;
      // A choice still unsaved keeps its message: Try again saves it first.
      errorKey = _retryRoute != null
          ? 'Your setup choice could not be saved. Try again.'
          : 'Your setup could not be checked. Your last choices are kept.';
    } finally {
      if (current()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// Ignore an outstanding read when leaving; it must not replace a later one.
  void cancelPending() {
    if (_disposed) return;
    if (loading) abandonRead?.call();
    _revision++;
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    if (loading) abandonRead?.call();
    _disposed = true;
    _revision++;
    super.dispose();
  }
}

/// Every field the guide view reads has the type it reads it as (a malformed row is a failed
/// check, never a crash while the page is built or a button is pressed).
bool validGuideSnapshot(Map<String, dynamic> snapshot) {
  final routes = snapshot['routes'];
  if (routes is! List) return false;
  final answer = snapshot['answer'];
  if (answer != null && answer is! String) return false;
  for (final route in routes) {
    if (route is! Map<String, dynamic>) return false;
    if (route['id'] is! String ||
        route['title'] is! String ||
        route['access'] is! String) {
      return false;
    }
    final command = route['command'];
    if (command != null && command is! String) return false;
    final steps = route['steps'];
    if (steps == null) continue;
    if (steps is! List) return false;
    for (final step in steps) {
      if (step is! Map<String, dynamic>) return false;
      if (step['title'] is! String ||
          step['detail'] is! String ||
          step['action'] is! String) {
        return false;
      }
      final action = step['action'] as String;
      if (const {
            'install-tool',
            'install-runtime',
            'download-starter',
          }.contains(action) &&
          step['target'] is! String) {
        return false;
      }
      if (action == 'download-starter' &&
          step['starter'] is! Map<String, dynamic>) {
        return false;
      }
      // Every other button passes the route's command (first_agent_view.dart).
      if (action.isNotEmpty &&
          !const {
            'install-tool',
            'install-runtime',
            'download-starter',
          }.contains(action) &&
          command is! String) {
        return false;
      }
    }
  }
  return true;
}
