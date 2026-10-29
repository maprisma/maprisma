import 'dart:io';
import 'package:asterism_core/asterism_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('asterism-help-'));
  tearDown(() => temp.deleteSync(recursive: true));

  CoreService core(String language) {
    final env = {
      'HOME': temp.path,
      'ASTERISM_DESKTOP': 'generic',
      'ASTERISM_DATA_DIR': '${temp.path}/data',
      'PATH': '${temp.path}/bin',
      'LANG': '$language.UTF-8',
    };
    return CoreService(environment: env);
  }

  test('the manual in the interface language, else English, else none', () {
    final data = Directory('${temp.path}/data')..createSync();
    expect(core('de_DE').dispatch('help.snapshot', {}), {'manual': false});
    expect(
      () => core('de_DE').dispatch('help.open_manual', {}),
      throwsFormatException,
    );
    File('${data.path}/user-manual.pdf').writeAsStringSync('%PDF en');
    final german = core('de_DE');
    expect(german.manualPath(), '${data.path}/user-manual.pdf');
    File('${data.path}/user-manual.de.pdf').writeAsStringSync('%PDF de');
    expect(german.manualPath(), '${data.path}/user-manual.de.pdf');
    expect(core('fr_FR').manualPath(), '${data.path}/user-manual.pdf');
    // A link in place of the file is not opened.
    File('${data.path}/user-manual.de.pdf').deleteSync();
    Link('${data.path}/user-manual.de.pdf').createSync('/etc/hostname');
    expect(german.manualPath(), '${data.path}/user-manual.pdf');
    expect(
      () => german.dispatch('help.snapshot', {'x': 1}),
      throwsFormatException,
    );
  });

  test('without xdg-open nothing is started', () {
    Directory('${temp.path}/data').createSync();
    File('${temp.path}/data/user-manual.pdf').writeAsStringSync('%PDF');
    expect(core('en_US').dispatch('help.open_manual', {}), {'opened': false});
  });
}
