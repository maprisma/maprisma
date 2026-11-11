import 'dart:convert';

import 'model_hub.dart' show boundedOutput;

/// ai_core.clipboard_text(terminal=True): the clipboard's plain text read with
/// `wl-paste` under a byte cap and a deadline — the toolkit's own paste
/// buffers whatever another app offers, with neither. Line breaks and tabs
/// stay; other control characters (ESC…) go. '' when the clipboard has no
/// text; null when the offer is too long, too slow or cannot be read.
const maxTerminalPaste = 1024 * 1024;
const _textTypes = [
  'text/plain;charset=utf-8',
  'text/plain',
  'UTF8_STRING',
  'TEXT',
  'STRING',
];

Future<String?> boundedClipboardText({
  int maxBytes = maxTerminalPaste,
  Duration timeout = const Duration(seconds: 2),
  Future<(List<int>, bool)> Function(List<String> argv, int maxBytes, Duration timeout)? run,
}) async {
  final read =
      run ??
      (List<String> argv, int max, Duration t) =>
          boundedOutput(argv, maxBytes: max, timeout: t);
  // One deadline for the whole paste (both reads together).
  final until = DateTime.now().add(timeout);
  Duration left() {
    final rest = until.difference(DateTime.now());
    return rest > Duration.zero ? rest : const Duration(milliseconds: 1);
  }

  final (types, _) = await read(['wl-paste', '--list-types'], 65536, left());
  // An empty clipboard makes wl-paste fail: nothing to paste, not an error.
  final offered = {
    for (final line in const LineSplitter().convert(
      utf8.decode(types, allowMalformed: true),
    ))
      line.trim(),
  };
  for (final mime in _textTypes) {
    if (!offered.contains(mime)) continue;
    final (data, ok) = await read([
      'wl-paste',
      '--no-newline',
      '--type',
      mime,
    ], maxBytes, left());
    if (!ok) return null;
    final text = utf8.decode(data, allowMalformed: true).replaceAll('\r\n', '\n');
    return String.fromCharCodes(
      text.runes.where(
        (c) => c == 10 || c == 9 || !(c < 32 || (c >= 127 && c < 160)),
      ),
    );
  }
  return '';
}
