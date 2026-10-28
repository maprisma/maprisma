// Development-only component differentials. Never imported by the application.
import 'dart:convert';
import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:asterism_core/src/adapters.dart';
import 'package:asterism_core/src/connect_apply.dart';
import 'package:asterism_core/src/line_diff.dart';
import 'package:asterism_core/src/model_hub.dart';
import 'package:asterism_core/src/context.dart';
import 'package:asterism_core/src/py_values.dart';
import 'package:asterism_core/src/py_yaml.dart';
import 'package:asterism_core/src/read_service.dart';
import 'package:asterism_core/src/security_reports.dart';
import 'package:asterism_core/src/session_readers.dart';
import 'package:asterism_core/src/usage_readers.dart';

Future<void> main() async {
  final identity = AppIdentity(),
      settings = SettingsStore(identity),
      i18n = ServiceI18n(identity, settings);
  // Write routes go to a full core; scans use its read service (one map).
  final core = CoreService();
  final reads = core.reads;
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
      } else if (request.method == 'dev.jsondumps') {
        final value = jsonDecode(params['text'] as String);
        result = {
          'flat': pyJsonDumps(value),
          'indented': pyJsonDumps(value, indent: 2, ensureAscii: false),
        };
      } else if (request.method == 'dev.mcpplan') {
        // The planned texts themselves (development probe only).
        final plan = core.mcp.plan(
          params['agent'] as String,
          params['name'] as String,
          [for (final a in params['sources'] as List) a as String],
          remove: params['remove'] as bool,
        );
        result = {
          'changes': [
            for (final c in plan.changes) {'path': c.path, 'new': c.next},
          ],
        };
      } else if (request.method == 'dev.yamldump') {
        result = {'text': pyYamlDump(jsonDecode(params['json'] as String))};
      } else if (request.method == 'dev.yamlload') {
        try {
          result = {'json': pyJsonDumps(pyYamlLoad(params['text'] as String))};
        } on UnsupportedError {
          result = {'unsupported': true};
        }
      } else if (request.method == 'dev.llmplan') {
        final rt = core.reads.inventory
            .collect(core.reads.catalog.scan(), remember: false)
            .runtimes
            .firstWhere((r) => r.key == params['runtime']);
        final plan = core.llm.plan(
          params['agent'] as String,
          rt,
          params['model'] as String? ?? '',
          params['use_now'] as bool? ?? false,
          remove: params['remove'] as bool,
        );
        result = {
          'changes': [
            for (final c in plan.changes) {'path': c.path, 'new': c.next},
          ],
          'contexts': [
            for (final c in plan.contexts) [c['model'], c['tokens']],
          ],
        };
      } else if (request.method == 'dev.hfparse') {
        // models_ctl.search/files on given API answers (the URL asked is returned).
        final urls = <String>[];
        final hub = ModelHub(
          jsonList: (url) async {
            urls.add(url);
            return params['items'] as List;
          },
        );
        try {
          result = {
            'found': params['kind'] == 'search'
                ? await hub.search(
                    params['query'] as String,
                    limit: params['limit'] as int,
                  )
                : await hub.files(params['repo'] as String),
            'urls': urls,
          };
        } on FormatException catch (e) {
          result = {'error': 'FormatException', 'message': e.message};
        }
      } else if (request.method == 'dev.fit') {
        final path = params['path'] as String;
        try {
          final meta = readGguf(path);
          result = {
            'layout': kvLayout(meta, params['cache'] as String).toString(),
            'best': [
              for (final v in params['vram'] as List)
                bestContext(path, v as int, params['cache'] as String),
            ],
          };
        } on FormatException catch (e) {
          result = {'error': e.message};
        }
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
        result = reads.inventory
            .collect(reads.catalog.scan(), remember: false)
            .toJson();
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
        result = readOnlyRoutes.contains(request.method)
            ? reads.dispatch(request.method, params)
            : core.dispatch(request.method, params);
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
