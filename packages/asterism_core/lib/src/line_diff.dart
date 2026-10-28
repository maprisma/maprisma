/// Python's str.splitlines() (no line ends kept).
List<String> pySplitlines(String text) {
  const breaks = {
    0x0a, 0x0b, 0x0c, 0x0d, 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029, //
  };
  final lines = <String>[];
  final runes = text.runes.toList();
  var start = 0;
  for (var i = 0; i < runes.length; i++) {
    if (!breaks.contains(runes[i])) continue;
    lines.add(String.fromCharCodes(runes.sublist(start, i)));
    if (runes[i] == 0x0d && i + 1 < runes.length && runes[i + 1] == 0x0a) i++;
    start = i + 1;
  }
  if (start < runes.length) {
    lines.add(String.fromCharCodes(runes.sublist(start)));
  }
  return lines;
}

/// The matched elements of difflib.SequenceMatcher(None, a, b) with its
/// default autojunk: the sum of get_matching_blocks() sizes.
int matchedCount(List<String> a, List<String> b) {
  final b2j = <String, List<int>>{};
  for (var i = 0; i < b.length; i++) {
    b2j.putIfAbsent(b[i], () => []).add(i);
  }
  if (b.length >= 200) {
    final ntest = b.length ~/ 100 + 1;
    b2j.removeWhere((_, indices) => indices.length > ntest);
  }
  (int, int, int) longest(int alo, int ahi, int blo, int bhi) {
    var besti = alo, bestj = blo, bestsize = 0;
    var j2len = <int, int>{};
    for (var i = alo; i < ahi; i++) {
      final next = <int, int>{};
      for (final j in b2j[a[i]] ?? const <int>[]) {
        if (j < blo) continue;
        if (j >= bhi) break;
        final k = next[j] = (j2len[j - 1] ?? 0) + 1;
        if (k > bestsize) {
          besti = i - k + 1;
          bestj = j - k + 1;
          bestsize = k;
        }
      }
      j2len = next;
    }
    // No junk function: popular lines still extend a match at both ends.
    while (besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1]) {
      besti--;
      bestj--;
      bestsize++;
    }
    while (besti + bestsize < ahi &&
        bestj + bestsize < bhi &&
        a[besti + bestsize] == b[bestj + bestsize]) {
      bestsize++;
    }
    return (besti, bestj, bestsize);
  }

  var total = 0;
  final queue = [(0, a.length, 0, b.length)];
  while (queue.isNotEmpty) {
    final (alo, ahi, blo, bhi) = queue.removeLast();
    final (i, j, k) = longest(alo, ahi, blo, bhi);
    if (k == 0) continue;
    total += k;
    if (alo < i && blo < j) queue.add((alo, i, blo, j));
    if (i + k < ahi && j + k < bhi) queue.add((i + k, ahi, j + k, bhi));
  }
  return total;
}

/// (added, removed) lines between two texts, as the preview counts them.
(int, int) lineChanges(String old, String next) {
  final a = pySplitlines(old), b = pySplitlines(next);
  final matched = matchedCount(a, b);
  return (b.length - matched, a.length - matched);
}
