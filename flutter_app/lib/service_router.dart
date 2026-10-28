import 'package:asterism_core/asterism_core.dart';
import 'service_transport.dart';
import 'python_transport.dart';

const develPythonFallback = bool.fromEnvironment(
  'ASTERISM_DEVEL',
  defaultValue: false,
);

final class ServiceRouter implements ServiceTransport {
  ServiceRouter(this.core, {required this.root});
  final ServiceTransport core;
  final String root;
  Future<PythonTransport>? _reference;
  bool _disposed = false;
  @override
  bool get isConnected => !_disposed && core.isConnected;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (_disposed) throw StateError('Service closed');
    if (portedRoutes.contains(method)) {
      final result = await core.call(method, params);
      if (develPythonFallback &&
          method == 'settings.update' &&
          params['values'] is Map &&
          (params['values'] as Map).containsKey('language') &&
          _reference != null) {
        final reference = _reference!;
        try {
          await (await reference).call('app.settings_changed');
        } catch (_) {
          // The write already succeeded. Retire the stale reference rather than
          // report a write failure or replay it. Its next request starts fresh.
          reference.then((r) => r.dispose(), onError: (Object _) {});
          if (identical(_reference, reference)) _reference = null;
        }
      }
      return result;
    }
    if (!develPythonFallback) throw ServiceError('unported_route');
    final reference = await (_reference ??= PythonTransport.start(root));
    if (_disposed) {
      reference.dispose();
      throw StateError('Service closed');
    }
    return reference.call(method, params);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    core.dispose();
    _reference?.then((r) => r.dispose(), onError: (Object _) {});
  }

  @override
  Future<void> shutdown() async {
    dispose();
    await core.shutdown();
    if (_reference != null) {
      try {
        await (await _reference!).shutdown();
      } catch (_) {}
    }
  }
}
