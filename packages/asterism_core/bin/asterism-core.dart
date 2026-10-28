// Plan-specified executable entry point.
// ignore_for_file: file_names
import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/plan_worker.dart';
import 'package:asterism_core/src/provider_watch.dart';

// `worker`: one private plan or provider operation; `provider-watch`: the
// service that starts local LLMs with their agents.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'worker') {
    exitCode = await runWorker(args.sublist(1));
    return;
  }
  if (args.isNotEmpty && args.first == 'provider-watch') {
    exitCode = await runProviderWatch(args.sublist(1));
    return;
  }
  if (args.isNotEmpty) {
    stderr.writeln('Unknown subcommand');
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
