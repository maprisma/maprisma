import 'dart:convert';

import 'package:maprisma_core/src/clipboard.dart';
import 'package:test/test.dart';

void main() {
  Future<(List<int>, bool)> Function(List<String>, int, Duration) fake(
    String types,
    String text, {
    bool ok = true,
  }) => (argv, max, _) async {
    if (argv.contains('--list-types')) return (utf8.encode(types), true);
    final bytes = utf8.encode(text);
    return (
      bytes.length > max ? bytes.sublist(0, max) : bytes,
      ok && bytes.length <= max,
    );
  };

  test('text with line breaks and tabs, no escape sequences', () async {
    expect(
      await boundedClipboardText(
        run: fake('text/plain\n', 'a\tb\r\nc\x1b[31m'),
      ),
      'a\tb\nc[31m',
    );
  });

  test('too long or too slow: null, nothing pasted', () async {
    expect(
      await boundedClipboardText(
        maxBytes: 4,
        run: fake('text/plain\n', 'too long'),
      ),
      isNull,
    );
    expect(
      await boundedClipboardText(run: fake('text/plain\n', 'x', ok: false)),
      isNull,
    );
  });

  test('no text offered: empty', () async {
    expect(await boundedClipboardText(run: fake('image/png\n', '')), '');
  });
}
