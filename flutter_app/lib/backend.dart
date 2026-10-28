import 'package:asterism_core/asterism_core.dart';
import 'service_transport.dart';
import 'isolate_transport.dart';
import 'service_router.dart';
export 'service_transport.dart';

typedef BackendError = ServiceError;

class Backend implements ServiceTransport {
  Backend.fromTransport(this.transport);
  final ServiceTransport transport;
  static Future<Backend> start(String root) async => Backend.fromTransport(
    ServiceRouter(await IsolateTransport.start(), root: root),
  );
  @override
  bool get isConnected => transport.isConnected;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) => transport.call(method, params);
  @override
  void dispose() => transport.dispose();
  @override
  Future<void> shutdown() => transport.shutdown();
}
