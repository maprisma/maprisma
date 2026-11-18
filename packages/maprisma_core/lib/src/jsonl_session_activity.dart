import 'dart:convert';

import 'activity_readers.dart' show metaText;

Map<String, dynamic> jsonlSessionActivity(
  String tail,
  String sessionId, {
  bool rollout = false,
}) {
  Map<String, dynamic>? request;
  final answers = <Map<String, dynamic>>[];
  final tools = <Map<String, dynamic>>[];
  final calls = <String, Map<String, dynamic>>{};
  final patches = <String, List<String>>{};
  final edits = <String, Map<String, dynamic>>{};
  final patchHeader = RegExp(
    r'^\*\*\* (?:(?:Add|Update|Delete) File|Move to): (.+)$',
    multiLine: true,
  );
  for (final line in const LineSplitter().convert(tail)) {
    if (line.length > 128 * 1024) continue;
    final dynamic row;
    try {
      row = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (row is! Map) continue;
    final message = rollout
        ? row['type'] == 'response_item'
              ? row['payload']
              : null
        : {'message', 'user', 'assistant'}.contains(row['type'])
        ? row['message']
        : null;
    if (message is! Map) continue;
    final at = row['timestamp'] is String
        ? DateTime.tryParse(
            row['timestamp'] as String,
          )?.toUtc().toIso8601String()
        : null;
    if (rollout && message['type'] != 'message') {
      final type = message['type'];
      final callId = message['call_id'];
      if (type == 'function_call' || type == 'custom_tool_call') {
        final name = metaText(message['name'], 128);
        if (name.isEmpty || tools.length >= 48) continue;
        final tool = <String, dynamic>{'at': at, 'name': name, 'status': null};
        tools.add(tool);
        if (callId is String) {
          calls[callId] = tool;
          if (name == 'apply_patch' && message['input'] is String) {
            patches[callId] = [
              for (final match
                  in patchHeader
                      .allMatches(message['input'] as String)
                      .take(48))
                if (metaText(match[1], 500) case final path
                    when path.isNotEmpty)
                  path,
            ];
          }
        }
      } else if (type == 'function_call_output' ||
          type == 'custom_tool_call_output') {
        final tool = calls.remove(callId);
        if (tool == null) continue;
        final output = message['output'];
        final patch = patches.remove(callId);
        if (patch != null &&
            output is String &&
            RegExp(
              r'^(?:Wall time: [^\n]*\n(?:Output:\n)?)?Success\. Updated the following files:',
            ).hasMatch(output)) {
          tool['status'] = 'completed';
          for (final path in patch) {
            if (edits.length >= 48) break;
            edits[path] = {'at': at, 'path': path};
          }
        }
      }
      continue;
    }
    final content = message['content'];
    final blocks = content is String
        ? [
            {'type': 'text', 'text': content},
          ]
        : content is List
        ? content.whereType<Map>()
        : const <Map>[];
    final text = blocks
        .where(
          (b) => (rollout ? {'input_text', 'output_text'} : {'text'}).contains(
            b['type'],
          ),
        )
        .where(
          (b) =>
              !rollout ||
              message['role'] != 'user' ||
              !(b['text'] is String &&
                  (b['text'] as String).trimLeft().startsWith(
                    RegExp(
                      r'<environment_context>|<user_instructions>|<permissions instructions>|# AGENTS\.md instructions',
                    ),
                  )),
        )
        .map((b) => metaText(b['text'], 2000))
        .where((value) => value.isNotEmpty)
        .take(8)
        .join('\n');
    if (message['role'] == 'user' && text.isNotEmpty) {
      request = {'at': at, 'text': text};
      answers.clear();
      tools.clear();
      calls.clear();
      patches.clear();
      edits.clear();
    } else if (message['role'] == 'assistant') {
      if (text.isNotEmpty && answers.length < 32) {
        answers.add({'at': at, 'text': text});
      }
      for (final block in blocks) {
        if (!{'toolCall', 'tool_use'}.contains(block['type'])) continue;
        final name = metaText(block['name'], 128);
        if (name.isNotEmpty && tools.length < 48) {
          tools.add({'at': at, 'name': name, 'status': null});
        }
      }
    }
  }
  final available = request != null || answers.isNotEmpty || tools.isNotEmpty;
  return {
    'status': !available
        ? 'unavailable'
        : request == null
        ? 'partial'
        : 'available',
    'session_id': available ? sessionId : null,
    'request': request,
    'answers': answers,
    'tool_calls': tools,
    'edited_files': edits.values.toList(),
  };
}
