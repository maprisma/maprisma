// An add-on left in the user folder that is refused (an Asterism-era copy, a
// broken file) must not hide the copy installed with the app; a verified user
// copy still wins; none verified: the user's copy with its refusal.
import 'dart:io';

import 'package:maprisma_core/src/addons.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String user, system;
  final fixture = p.join('test', 'fixtures', 'addons', 'llm-strata');

  void copy(String to) {
    Directory(to).createSync(recursive: true);
    for (final f in Directory(fixture).listSync()) {
      File(f.path).copySync(p.join(to, p.basename(f.path)));
    }
  }

  void spoil(String folder) =>
      File(p.join(folder, 'addon.json')).writeAsStringSync(
        File(p.join(folder, 'addon.json')).readAsStringSync().replaceFirst(
          'maprisma >= 0.14.1',
          'asterism >= 0.11.1',
        ),
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('addon-choice');
    user = p.join(temp.path, 'user');
    system = p.join(temp.path, 'system');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  List<(String, String)> chosen() => [
    for (final a in AddonRegistry(AddonVerifier(Posix()), [
      user,
      system,
    ]).chosen())
      (a.state, p.dirname(a.folder)),
  ];

  test('a refused user copy does not hide the app\'s own', () {
    copy(p.join(system, 'llm-strata'));
    copy(p.join(user, 'llm-strata'));
    spoil(p.join(user, 'llm-strata'));
    expect(chosen(), [('verified', system)]);
  });

  test('a verified user copy still wins', () {
    copy(p.join(system, 'llm-strata'));
    copy(p.join(user, 'llm-strata'));
    expect(chosen(), [('verified', user)]);
  });

  test('none verified: the user copy with its refusal', () {
    copy(p.join(user, 'llm-strata'));
    spoil(p.join(user, 'llm-strata'));
    copy(p.join(system, 'llm-strata'));
    spoil(p.join(system, 'llm-strata'));
    expect(chosen(), [('refused', user)]);
  });
}
