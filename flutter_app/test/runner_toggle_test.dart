// The runner's --toggle rule (linux/runner/toggle_rule.h), compiled with the
// system's C compiler and glib; skipped where neither is installed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final header = File('linux/runner/toggle_rule.h').absolute.path;
  late Directory dir;
  String? exe;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('runner-toggle');
    final flags = await Process.run('pkg-config', [
      '--cflags',
      '--libs',
      'glib-2.0',
    ]);
    if (flags.exitCode != 0) return;
    File('${dir.path}/main.c').writeAsStringSync(
      '#include <stdlib.h>\n#include "$header"\n'
      'int main(int argc, char** argv) { return maprisma_toggle_step('
      'atoi(argv[1]), atoll(argv[2]), atoll(argv[3])); }\n',
    );
    final cc = await Process.run('cc', [
      '-o',
      '${dir.path}/check',
      '${dir.path}/main.c',
      ...'${flags.stdout}'.trim().split(RegExp(r'\s+')),
    ]);
    if (cc.exitCode == 0) exe = '${dir.path}/check';
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  // 0 hide, 1 show, 2 stay
  int step(bool visible, int hiddenAt, int now) => Process.runSync(exe!, [
    '${visible ? 1 : 0}',
    '$hiddenAt',
    '$now',
  ]).exitCode;

  test('a shown window hides, focused or not; a hidden one shows', () {
    if (exe == null) {
      markTestSkipped('no C compiler or glib');
      return;
    }
    // COSMIC: the panel click took the focus, the window is still shown
    expect(step(true, 0, 5000000), 0);
    expect(step(false, 0, 5000000), 1);
    // a popup that hid itself on this very click stays hidden
    expect(step(false, 4800000, 5000000), 2);
    // long ago: shown again
    expect(step(false, 1000000, 5000000), 1);
  });
}
