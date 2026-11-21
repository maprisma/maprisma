import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maprisma/backend.dart';
import 'package:maprisma/main.dart';

class _ClosingTransport implements ServiceTransport {
  _ClosingTransport({required this.connected});
  bool connected;
  bool refuseShutdown = true;
  int shutdowns = 0;

  /// The summaries to answer in turn; after them, a failing summary.
  List<Map<String, dynamic>>? summaries;

  @override
  bool get isConnected => connected;

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (!connected) throw StateError('Disconnected fixture');
    if (method == 'features.summary') {
      final queue = summaries;
      if (queue == null) return {'running': 0, 'pausing': 0, 'connected': true};
      if (queue.isEmpty) throw BackendError('feature_disconnected');
      return queue.removeAt(0);
    }
    if (method == 'features.shutdown') {
      if (refuseShutdown) throw BackendError('project_still_pausing');
      return {'ok': true};
    }
    throw StateError('Unavailable fixture snapshot');
  }

  @override
  void dispose() {}

  @override
  Future<void> shutdown() async => shutdowns++;
}

void main() {
  testWidgets('a disconnected backend cannot trap the app window open', (
    tester,
  ) async {
    var destroyed = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        if (call.method == 'destroy') destroyed = true;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final transport = _ClosingTransport(connected: false);
    await tester.pumpWidget(
      MaprismaApp(connectBackend: () async => Backend.fromTransport(transport)),
    );
    await tester.pumpAndSettle();
    final dynamic state = tester.state(find.byType(MaprismaApp));
    state.onWindowClose();
    await tester.pump(const Duration(milliseconds: 100));
    expect(destroyed, isTrue);
    expect(transport.shutdowns, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unconfirmed live cleanup keeps the window open and can be retried',
    (tester) async {
      var destroyed = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          if (call.method == 'destroy') destroyed = true;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      final transport = _ClosingTransport(connected: true);
      await tester.pumpWidget(
        MaprismaApp(
          connectBackend: () async => Backend.fromTransport(transport),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(MaprismaApp));
      state.onWindowClose();
      await tester.pump(const Duration(milliseconds: 100));
      expect(destroyed, isFalse);
      expect(transport.shutdowns, 0);
      transport.refuseShutdown = false;
      state.onWindowClose();
      await tester.pump(const Duration(milliseconds: 100));
      expect(destroyed, isTrue);
      expect(transport.shutdowns, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a failed summary keeps the running agents for the close question',
    (tester) async {
      var destroyed = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          if (call.method == 'destroy') destroyed = true;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          null,
        ),
      );
      final transport = _ClosingTransport(connected: true)
        ..refuseShutdown = false
        ..summaries = [
          {'running': 1, 'pausing': 0, 'connected': true},
        ];
      await tester.pumpWidget(
        MaprismaApp(
          connectBackend: () async => Backend.fromTransport(transport),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      // The next poll fails: the backend is unreachable for a moment.
      await tester.pump(const Duration(seconds: 3));
      final dynamic state = tester.state(find.byType(MaprismaApp));
      state.onWindowClose();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('Close Maprisma and stop its running agents?'),
        findsOneWidget,
      );
      expect(destroyed, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(destroyed, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
