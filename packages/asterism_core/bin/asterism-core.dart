// Plan-specified executable entry point.
// ignore_for_file: file_names
import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';

// Worker and provider-watch subcommands belong to subsequent reviewed phases.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln('No subcommands implemented in phase 1');
    exitCode = 64;
    return;
  }
  final service = CoreService();
  final frame = <int>[];
  var oversized = false;
  void reply() {
    if (oversized) {
      stdout.writeln(
        jsonEncode({
          'id': null,
          'error': {'code': 'request_too_large'},
        }),
      );
    } else {
      try {
        stdout.writeln(service.handle(utf8.decode(frame)));
      } on FormatException {
        stdout.writeln(
          jsonEncode({
            'id': null,
            'error': {'code': 'invalid_request'},
          }),
        );
      }
    }
    frame.clear();
    oversized = false;
  }

  await for (final chunk in stdin) {
    for (final byte in chunk) {
      if (byte == 10) {
        reply();
      } else if (!oversized) {
        if (frame.length + 1 >= maxRequest) {
          frame.clear();
          oversized = true;
        } else {
          frame.add(byte);
        }
      }
    }
  }
  if (oversized || frame.isNotEmpty) reply();
}
