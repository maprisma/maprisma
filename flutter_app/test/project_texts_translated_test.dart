import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app reads its texts only from assets/translations (built by
/// tools/flutter-assets.py from its KEYS): every text the Projects tab and
/// the AI Project Center page show must be there in all eight languages
/// (task 086 review round 2).
void main() {
  test('the Projects tab and the Project Center page are translated', () {
    final used = RegExp(r"""tr\(\s*'((?:[^'\\]|\\.)*)'\s*[,)]""");
    final keys = {
      for (final file in ['lib/ai_project_center.dart', 'lib/main_tabs.dart'])
        for (final match in used.allMatches(File(file).readAsStringSync()))
          match.group(1)!.replaceAll(r"\'", "'"),
    };
    expect(keys, isNotEmpty);
    for (final code in ['de', 'es', 'fr', 'it', 'nl', 'pl', 'pt']) {
      final table =
          jsonDecode(File('assets/translations/$code.json').readAsStringSync())
              as Map<String, dynamic>;
      final missing = [
        for (final key in keys)
          if (table[key] is! String) key,
      ];
      expect(missing, isEmpty, reason: '$code is missing these texts');
    }
  });
}
