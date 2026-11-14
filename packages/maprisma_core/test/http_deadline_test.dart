import 'dart:async';
import 'dart:io';

import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:maprisma_core/src/provider_ops.dart';
import 'package:test/test.dart';

/// A loopback server that sends headers and then one body byte every 50 ms
/// (with or without Connection: close), or a normal answer.
Future<ServerSocket> _serve(String mode) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) async {
    socket.listen((_) {}, onError: (_) {});
    if (mode == 'ok') {
      socket.write(
        'HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{"ok": true}',
      );
      await socket.flush();
      await socket.close();
      return;
    }
    socket.write(
      'HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n'
      '${mode == 'close' ? 'Connection: close\r\n' : ''}\r\n',
    );
    try {
      for (var i = 0; i < 400; i++) {
        socket.add([32]);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on Object {
      // the client went away
    }
  });
  return server;
}

void main() {
  final uid = Posix().uid;

  for (final mode in ['trickle', 'close']) {
    test('a trickling reply ($mode) stops at the whole deadline', () async {
      final server = await _serve(mode);
      addTearDown(server.close);
      final watch = Stopwatch()..start();
      final reply = await httpJson(
        server.port,
        '/',
        uid,
        timeout: const Duration(milliseconds: 600),
      );
      expect(reply, isNull);
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });
  }

  test('a normal reply, twice', () async {
    final server = await _serve('ok');
    addTearDown(server.close);
    for (var i = 0; i < 2; i++) {
      expect(
        await httpJson(
          server.port,
          '/',
          uid,
          timeout: const Duration(seconds: 2),
        ),
        {'ok': true},
      );
    }
  });
}
