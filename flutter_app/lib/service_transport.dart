abstract interface class ServiceTransport {
  bool get isConnected;
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]);
  void dispose();
  Future<void> shutdown();
}
