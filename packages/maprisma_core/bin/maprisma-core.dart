// Plan-specified executable entry point.
// ignore_for_file: file_names
import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/plan_worker.dart';
import 'package:maprisma_core/src/agent_progress.dart';
import 'package:maprisma_core/src/ai_activity_log.dart';
import 'package:maprisma_core/src/provider_scans.dart';
import 'package:maprisma_core/src/provider_watch.dart';

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
  if (args.firstOrNull == 'activity-log') {
    try {
      final options = <String, String>{};
      const keys = {
        '--format': 'format',
        '--from-day': 'from_day',
        '--through-day': 'through_day',
        '--cursor': 'cursor',
      };
      for (var i = 1; i < args.length; i += 2) {
        final key = keys[args[i]];
        if (key == null || options.containsKey(key) || i + 1 >= args.length) {
          throw const FormatException();
        }
        options[key] = args[i + 1];
      }
      final format = options.remove('format') ?? 'text';
      final cursor = options.remove('cursor');
      if (format != 'text' && format != 'json') throw const FormatException();
      final service = CoreService(migrate: false);
      try {
        final report = await service.dispatchAsync('activitylog.report', {
          ...options,
          if (cursor != null) 'cursor': int.parse(cursor),
        });
        stdout.writeln(formatActivityLog(report, json: format == 'json'));
      } finally {
        service.dispose();
      }
    } on FormatException {
      stderr.writeln(
        'Usage: maprisma-core activity-log [--format text|json] '
        '[--from-day YYYY-MM-DD] [--through-day YYYY-MM-DD] [--cursor N]',
      );
      exitCode = 64;
    }
    return;
  }
  final activityMcp =
      args.length == 1 &&
      {'activity-mcp', 'activity-log-mcp'}.contains(args.single);
  if (args.isNotEmpty && !activityMcp) {
    stderr.writeln('Unknown subcommand');
    exitCode = 64;
    return;
  }
  final service = CoreService(migrate: !activityMcp);
  final frame = <int>[];
  var oversized = false;
  Future<void> reply() async {
    if (oversized) {
      stdout.writeln(
        jsonEncode({
          'id': null,
          'error': {'code': 'request_too_large'},
        }),
      );
    } else {
      try {
        if (activityMcp) {
          final response = await activityMcpReply(
            jsonDecode(utf8.decode(frame)),
            AgentProgress(ProviderScans(service.reads.files)),
            service.reads.catalog.adapters.map((a) => a.command).toSet(),
            logReport: args.single == 'activity-log-mcp'
                ? (params) =>
                      service.dispatchAsync('activitylog.report', params)
                : null,
          );
          if (response != null) stdout.writeln(jsonEncode(response));
        } else {
          stdout.writeln(await service.handleAsync(utf8.decode(frame)));
        }
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
        await reply();
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
  if (oversized || frame.isNotEmpty) await reply();
  service.dispose();
}
