// Development-only component differentials. Never imported by the application.
import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/adapters.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/line_diff.dart';
import 'package:asterism_core/src/read_service.dart';
import 'package:asterism_core/src/security_reports.dart';
import 'package:asterism_core/src/session_readers.dart';
import 'package:asterism_core/src/usage_readers.dart';

Future<void> main() async {
  final identity = AppIdentity(),
      settings = SettingsStore(identity),
      desktop = detectDesktop(identity, Posix()),
      i18n = ServiceI18n(identity, settings);
  final reads = ReadService(identity, settings, desktop, i18n);
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    int? id;
    Map<String, dynamic> response;
    try {
      final request = Request.decode(line);
      id = request.id;
      final params = request.params;
      Map<String, dynamic> result;
      if (request.method == 'adapter.validate') {
        if (params.keys.toSet().difference({'file', 'facts'}).isNotEmpty ||
            params.length != 1) {
          throw const FormatException('Invalid adapter fixture');
        }
        Adapter adapter;
        if (params['file'] is String) {
          final path = params['file'] as String;
          if (path.startsWith('/') || path.split('/').contains('..')) {
            throw const FormatException('Fixture path escapes HOME');
          }
          adapter = Adapter.load('${Platform.environment['HOME']}/$path');
        } else {
          adapter = Adapter(Map<String, dynamic>.from(params['facts'] as Map));
        }
        result = {'command': adapter.command, 'name': adapter.name};
      } else if (request.method == 'dev.linechanges') {
        final (added, removed) = lineChanges(
          params['old'] as String,
          params['new'] as String,
        );
        result = {'added': added, 'removed': removed};
      } else if (request.method == 'dev.undo') {
        // Undo of a backup folder either side made (development probe only).
        result = {
          'restored': ConfigFiles(
            Posix(),
            identity.home,
          ).undo(params['folder'] as String),
        };
      } else if (request.method == 'scan.catalog') {
        if (params.isNotEmpty) throw const FormatException('Unexpected params');
        result = {
          'agents': reads.catalog.scan().map((a) => a.toJson()).toList(),
        };
      } else if (request.method == 'scan.inventory') {
        if (params.isNotEmpty) throw const FormatException('Unexpected params');
        result = reads.inventory.collect(reads.catalog.scan()).toJson();
      } else if ([
        'scan.sessions',
        'scan.security',
        'scan.costs',
        'scan.usage',
      ].contains(request.method)) {
        if (params.length != 1 || params['command'] is! String) {
          throw const FormatException('Expected command');
        }
        final adapter = reads.catalog.adapter(params['command']);
        if (adapter == null) throw const FormatException('Unknown agent');
        if (request.method == 'scan.security') {
          result = SecurityReports(reads.files, i18n).agent(adapter);
        } else {
          final sessions = SessionReaders(reads.files).read(adapter);
          if (request.method == 'scan.sessions') {
            result = {
              'sessions': {
                for (final e in sessions.entries) e.key: e.value.toJson(),
              },
            };
          } else {
            final usage = UsageReaders(reads.files);
            result = {
              'value': request.method == 'scan.costs'
                  ? usage.costs(adapter, collected: sessions)
                  : usage.fromSessions(sessions, 'fixture'),
            };
          }
        }
      } else {
        result = reads.dispatch(request.method, params);
      }
      response = {'id': id, 'result': result};
    } catch (_) {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    }
    stdout.writeln(jsonEncode(response));
    await Future<void>.delayed(Duration.zero);
  }
}
