import 'dart:io';

import 'package:maprisma_core/maprisma_core.dart';

import 'service_transport.dart';
import 'isolate_transport.dart';
export 'core_client.g.dart';
export 'service_transport.dart';

typedef BackendError = ServiceError;

/// A Devel build (the preview bundle): its core must never manage the user
/// service of an installed Maprisma.
const develBuild = bool.fromEnvironment('MAPRISMA_DEVEL', defaultValue: false);

/// The core's environment: this process's, marked in a Devel build.
Map<String, String>? coreEnvironment({
  bool devel = develBuild,
  Map<String, String>? environment,
}) => devel
    ? {...(environment ?? Platform.environment), 'MAPRISMA_FLUTTER_DEVEL': '1'}
    : environment;

/// The app's service: the Dart core in a background isolate. Every route is
/// the core's; one it does not know is refused (unported_route).
class Backend implements ServiceTransport {
  Backend.fromTransport(this.transport);
  final ServiceTransport transport;
  static Future<Backend> start() async => Backend.fromTransport(
    await IsolateTransport.start(environment: coreEnvironment()),
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
