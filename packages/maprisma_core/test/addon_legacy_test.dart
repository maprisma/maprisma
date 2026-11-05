// An add-on signed for Asterism (this app's old name, its old key), as copied
// into the user folder at the rename: never loaded, but its card says what it
// is instead of "not signed".
import 'dart:io';

import 'package:maprisma_core/src/addons.dart';
import 'package:maprisma_core/src/posix_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String folder;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('addon-legacy');
    folder = p.join(temp.path, 'agent-goose');
    Directory(folder).createSync();
    final fixture = p.join(
      'test',
      'fixtures',
      'addons',
      'legacy',
      'agent-goose',
    );
    for (final f in Directory(fixture).listSync()) {
      File(f.path).copySync(p.join(folder, p.basename(f.path)));
    }
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('an Asterism-era add-on is recognised, never loaded', () {
    final item = AddonVerifier(Posix()).verify(folder);
    expect((item.state, item.reason), ('refused', legacyReason));
  });

  test('a changed manifest is an ordinary refusal', () {
    final manifest = File(p.join(folder, 'MANIFEST.sha256'));
    manifest.writeAsStringSync('${manifest.readAsStringSync()}\n');
    final item = AddonVerifier(Posix()).verify(folder);
    expect(
      (item.state, item.reason),
      ('refused', 'not signed by Uwe Bruckhaus'),
    );
  });
}
