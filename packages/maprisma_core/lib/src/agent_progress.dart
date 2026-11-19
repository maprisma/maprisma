import 'protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_halt.dart';
import 'provider_scans.dart';
import 'pty_sessions.dart' show processIdentity;

final class AgentProgress {
  AgentProgress(this.scans);
  final ProviderScans scans;

  String? _file(int pid, String start) {
    final runtime = scans.files.identity.environment['XDG_RUNTIME_DIR'];
    if (runtime == null || !p.isAbsolute(runtime)) return null;
    return p.join(runtime, 'maprisma', 'progress', '$pid-$start.json');
  }

  Map<String, dynamic>? read(String command, String instance) {
    final match = RegExp(
      r'^([1-9][0-9]{0,9}):([0-9]{1,20})$',
    ).firstMatch(instance);
    if (match == null) return null;
    final pid = int.parse(match[1]!);
    final start = match[2]!;
    final file = _file(pid, start);
    if (file == null ||
        !aliveSince(pid, 0, scans.files.posix) ||
        processIdentity(pid)?.$3 != start ||
        !(agentInstancePids(scans, {command})[command]?.contains(pid) ??
            false)) {
      return null;
    }
    final data = _readReport(file);
    return processIdentity(pid)?.$3 == start ? data : null;
  }

  Map<String, List<Map<String, dynamic>>> snapshot(Set<String> commands) {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final entry in agentInstancePids(scans, commands).entries) {
      for (final pid in entry.value) {
        final start = processIdentity(pid)?.$3;
        if (start == null || !aliveSince(pid, 0, scans.files.posix)) continue;
        final path = _file(pid, start);
        final report = path == null ? null : _readReport(path);
        if (processIdentity(pid)?.$3 != start) continue;
        (result[entry.key] ??= []).add({
          'id': '$pid:$start',
          'pid': pid,
          'progress': report,
        });
      }
    }
    return result;
  }

  Map<String, dynamic>? _readReport(String path) {
    final data = scans.files.json(path, limit: 8192);
    final step = data['step'], done = data['done'], total = data['total'];
    final note = data['note'], at = data['at'];
    if (step is! String ||
        done is! int ||
        total is! int ||
        done < 0 ||
        total < 1 ||
        done > total ||
        (note != null && note is! String) ||
        at is! String ||
        DateTime.tryParse(at) == null) {
      return null;
    }
    return {'step': step, 'done': done, 'total': total, 'note': note, 'at': at};
  }

  bool report(Set<String> commands, Map arguments) {
    final step = arguments['step'];
    final done = arguments['done'];
    final total = arguments['total'];
    final note = arguments['note'];
    if (arguments.keys.any(
          (key) => !{'step', 'done', 'total', 'note'}.contains(key),
        ) ||
        step is! String ||
        step.trim().isEmpty ||
        step.length > 240 ||
        done is! int ||
        total is! int ||
        done < 0 ||
        total < 1 ||
        total > 1000000 ||
        done > total ||
        (note != null && (note is! String || note.length > 1000))) {
      throw const FormatException('Invalid progress arguments');
    }
    final owner = ancestors(pid, scans.files.posix);
    final instances = agentInstancePids(
      scans,
      commands,
    ).values.expand((v) => v).toSet();
    final process = owner.where(instances.contains).firstOrNull;
    if (process == null) return false;
    final start = processIdentity(process)?.$3;
    if (start == null ||
        !aliveSince(process, 0, scans.files.posix) ||
        !ancestors(pid, scans.files.posix).contains(process) ||
        processIdentity(process)?.$3 != start) {
      return false;
    }
    final path = _file(process, start);
    if (path == null) return false;
    String clean(String text) => text
        .replaceAll(
          RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
          ' ',
        )
        .trim();
    final label = clean(step);
    if (label.isEmpty) throw const FormatException('Invalid progress step');
    try {
      scans.files.posix.atomicWrite(
        path,
        utf8.encode(
          jsonEncode({
            'step': label,
            'done': done,
            'total': total,
            'note': note is String ? clean(note) : null,
            'at': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
      );
      return processIdentity(process)?.$3 == start;
    } on FileSystemException {
      return false;
    }
  }
}

const _logTool = {
  'name': 'activity_log_report',
  'description': 'Read retained local Maprisma activity observations.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'from_day': {'type': 'string'},
      'through_day': {'type': 'string'},
      'cursor': {'type': 'integer'},
    },
    'additionalProperties': false,
  },
};

const _tool = {
  'name': 'report_progress',
  'description': 'Report progress for this running agent in Maprisma.',
  'inputSchema': {
    'type': 'object',
    'properties': {
      'step': {'type': 'string'},
      'done': {'type': 'integer'},
      'total': {'type': 'integer'},
      'note': {'type': 'string'},
    },
    'required': ['step', 'done', 'total'],
    'additionalProperties': false,
  },
};

const _reportTools = [
  {
    'name': 'reports_list',
    'description': 'List saved Maprisma reports, optionally searching by text.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
        'cursor': {'type': 'integer'},
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'reports_get',
    'description': 'Read a saved Maprisma report.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'integer'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
  },
];

Future<Map<String, Object?>?> activityMcpReply(
  dynamic frame,
  AgentProgress progress,
  Set<String> commands, {
  FutureOr<Map<String, dynamic>> Function(Map<String, dynamic>)? logReport,
  Map<String, dynamic> Function(String, Map<String, dynamic>)? savedReports,
}) async {
  if (frame is! Map || frame['jsonrpc'] != '2.0') {
    return {
      'jsonrpc': '2.0',
      'id': null,
      'error': {'code': -32600, 'message': 'Invalid request'},
    };
  }
  if (!frame.containsKey('id')) return null;
  final reply = <String, Object?>{'jsonrpc': '2.0', 'id': frame['id']};
  final params = frame['params'];
  switch (frame['method']) {
    case 'initialize':
      reply['result'] = {
        'protocolVersion': '2024-11-05',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'Maprisma activity', 'version': '1'},
      };
    case 'ping':
      reply['result'] = {};
    case 'tools/list':
      reply['result'] = {
        'tools': [
          logReport == null ? _tool : _logTool,
          if (savedReports != null) ..._reportTools,
        ],
      };
    case 'tools/call':
      if (savedReports != null &&
          params is Map &&
          {'reports_list', 'reports_get'}.contains(params['name'])) {
        final arguments = params['arguments'] ?? <String, dynamic>{};
        final method = params['name'] == 'reports_list'
            ? 'reports.list'
            : 'reports.get';
        var error = false;
        Map<String, dynamic> payload;
        try {
          if (arguments is! Map<String, dynamic>) throw const FormatException();
          payload = savedReports(method, arguments);
        } on FormatException {
          error = true;
          payload = {'code': 'invalid_request'};
        } on ServiceError catch (e) {
          error = true;
          payload = {'code': e.code};
        }
        reply['result'] = {
          'content': [
            {'type': 'text', 'text': jsonEncode(payload)},
          ],
          'isError': error,
        };
      } else if (logReport != null &&
          params is Map &&
          params['name'] == 'activity_log_report') {
        try {
          final arguments = params['arguments'] ?? const <String, dynamic>{};
          if (arguments is! Map<String, dynamic> ||
              arguments.keys.any(
                (k) => !{'from_day', 'through_day', 'cursor'}.contains(k),
              )) {
            throw const FormatException('Invalid report arguments');
          }
          reply['result'] = {
            'content': [
              {'type': 'text', 'text': jsonEncode(await logReport(arguments))},
            ],
          };
        } on FormatException {
          reply['error'] = {'code': -32602, 'message': 'Invalid tool call'};
        }
      } else if (logReport == null &&
          params is Map &&
          params['name'] == 'report_progress' &&
          params['arguments'] is Map) {
        var accepted = false;
        try {
          accepted = progress.report(commands, params['arguments'] as Map);
        } on FormatException {
          // Return the tool failure on the same request.
        }
        reply['result'] = {
          'content': [
            {
              'type': 'text',
              'text': jsonEncode({'accepted': accepted}),
            },
          ],
          'isError': !accepted,
        };
      } else {
        reply['error'] = {'code': -32602, 'message': 'Invalid tool call'};
      }
    default:
      reply['error'] = {'code': -32601, 'message': 'Method not found'};
  }
  return reply;
}
