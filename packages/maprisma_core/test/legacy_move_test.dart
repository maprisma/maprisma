import 'dart:io';

import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/legacy_move.dart';
import 'package:test/test.dart';

/// Asterism → Maprisma: config, add-ons and state copied once (modes kept,
/// links as links), the cache not, nothing of Asterism changed; no copy when
/// Maprisma's config exists or there is nothing to copy.
void main() {
  late Directory home;
  late AppIdentity identity;
  setUp(() {
    home = Directory.systemTemp.createTempSync('legacy-move');
    identity = AppIdentity(environment: {'HOME': home.path});
  });
  tearDown(() => home.deleteSync(recursive: true));

  File put(String path, String text, {int mode = 384}) {
    final file = File('${home.path}/$path')..createSync(recursive: true);
    file.writeAsStringSync(text);
    Process.runSync('chmod', [mode.toRadixString(8), file.path]);
    return file;
  }

  int mode(String path) => File('${home.path}/$path').statSync().mode & 0x1ff;

  test('copied once, Asterism untouched', () {
    put('.config/asterism/settings.json', '{"language": "de"}');
    put('.config/asterism/mcp-servers.json', '{"servers": {}}');
    put(
      '.config/asterism/connection-backups/20261030-100000-000000/manifest.json',
      '[]',
    );
    Link('${home.path}/.config/asterism/link').createSync('/etc/hostname');
    put('.local/share/asterism/addons/agent-pi/addon.toml', 'x', mode: 420);
    put('.local/state/asterism/jobs.json', '{}');
    put('.cache/asterism/catalog.json', '{}');

    expect(moveFromAsterism(identity), isNull);
    expect(
      File('${home.path}/.config/maprisma/settings.json').readAsStringSync(),
      '{"language": "de"}',
    );
    expect(mode('.config/maprisma/settings.json'), 384); // 0600 kept
    expect(
      File(
        '${home.path}/.config/maprisma/connection-backups/20261030-100000-000000/manifest.json',
      ).existsSync(),
      isTrue,
    );
    expect(
      Link('${home.path}/.config/maprisma/link').targetSync(),
      '/etc/hostname',
    ); // a link stays a link
    expect(mode('.local/share/maprisma/addons/agent-pi/addon.toml'), 420);
    expect(
      File('${home.path}/.local/state/maprisma/jobs.json').existsSync(),
      isTrue,
    );
    expect(Directory('${home.path}/.cache/maprisma').existsSync(), isFalse);
    expect(
      File('${home.path}/.config/asterism/settings.json').existsSync(),
      isTrue,
    ); // nothing of Asterism removed

    // Once: a later change in Asterism's folder is not copied again.
    put('.config/asterism/settings.json', '{"language": "fr"}');
    expect(moveFromAsterism(identity), isNull);
    expect(
      File('${home.path}/.config/maprisma/settings.json').readAsStringSync(),
      '{"language": "de"}',
    );
    expect(
      home.listSync(recursive: true).where((e) => e.path.contains('.moving-')),
      isEmpty,
    );
  });

  test('nothing to copy: nothing made', () {
    expect(moveFromAsterism(identity), isNull);
    expect(Directory('${home.path}/.config/maprisma').existsSync(), isFalse);
  });
}
