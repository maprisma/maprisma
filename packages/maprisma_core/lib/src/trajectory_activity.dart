import 'dart:convert';
import 'dart:typed_data';

import 'sqlite_numbers.dart';

/// Read the current turn from format-0 trajectory steps. Query only the
/// committed snapshot. Payloads from newer formats remain opaque.
Map<String, dynamic> trajectoryActivity(
  SqliteNumbers sqlite,
  String path,
  String sessionId,
) {
  final rows = sqlite.select(
    path,
    'SELECT step_type, status, step_format, '
    'CASE WHEN length(step_payload) <= 65536 THEN step_payload END '
    'FROM steps WHERE idx >= (SELECT COALESCE(MAX(idx), 0) FROM steps '
    'WHERE step_type = 14) ORDER BY idx DESC LIMIT 64',
    maxRows: 64,
    blobs: true,
  );
  Map<String, dynamic>? request;
  final answers = <Map<String, dynamic>>[];
  final tools = <Map<String, dynamic>>[];
  final edits = <Map<String, dynamic>>[];
  var partial = false;
  for (final [type, status, format, payload] in rows.reversed) {
    if (format != 0 || payload is! Uint8List) {
      partial = true;
      continue;
    }
    try {
      switch (type) {
        case 14:
          final text = trajectoryText(payload, [19, 2]);
          if (text.isNotEmpty) request = {'at': null, 'text': text};
        case 15:
          final text = trajectoryText(payload, [20, 1]);
          if (text.isNotEmpty) answers.add({'at': null, 'text': text});
        case 132:
          final name = trajectoryText(payload, [5, 4, 2]);
          if (!RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(name)) {
            partial = true;
            continue;
          }
          final completed = status == 3;
          tools.add({
            'at': null,
            'name': name,
            'status': completed ? 'completed' : null,
          });
          if (completed && name == 'write_file') {
            final path = trajectoryText(payload, [140, 1, 2]);
            if (path.startsWith('/')) edits.add({'at': null, 'path': path});
          }
        default:
          partial = true;
      }
    } on FormatException {
      partial = true;
    }
  }
  final available = request != null || answers.isNotEmpty || tools.isNotEmpty;
  return {
    'status': !available
        ? 'unavailable'
        : partial
        ? 'partial'
        : 'available',
    'session_id': available ? sessionId : null,
    'request': request,
    'answers': answers,
    'tool_calls': tools,
    'edited_files': edits,
  };
}

String trajectoryText(Uint8List bytes, List<int> path) {
  for (final tag in path) {
    final field = _field(bytes, tag);
    if (field == null) return '';
    bytes = field;
  }
  final text = utf8
      .decode(bytes)
      .replaceAll(
        RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'),
        '',
      )
      .trim();
  return String.fromCharCodes(text.runes.take(2000));
}

Uint8List? _field(Uint8List bytes, int wanted) {
  var cursor = 0;
  int varint() {
    var value = 0;
    for (var i = 0; i < 10 && cursor < bytes.length; i++) {
      final octet = bytes[cursor++];
      if (i == 9 && octet > 1) break;
      value |= (octet & 127) << (7 * i);
      if (octet < 128) return value;
    }
    throw const FormatException('Invalid protobuf varint');
  }

  while (cursor < bytes.length) {
    final key = varint();
    final tag = key >> 3;
    if (tag <= 0 || tag > 0x1fffffff) break;
    switch (key & 7) {
      case 0:
        varint();
      case 1:
        cursor += 8;
      case 2:
        final size = varint();
        if (size < 0 || size > bytes.length - cursor) {
          throw const FormatException('Invalid protobuf field length');
        }
        if (tag == wanted) {
          return Uint8List.sublistView(bytes, cursor, cursor + size);
        }
        cursor += size;
      case 5:
        cursor += 4;
      default:
        throw const FormatException('Unsupported protobuf wire type');
    }
  }
  if (cursor != bytes.length) {
    throw const FormatException('Truncated protobuf field');
  }
  return null;
}
