import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:maprisma_core/src/core_assets.g.dart' show defaults;

void main() {
  late Directory temp;
  late CoreService core;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('maprisma-core-test-');
    core = CoreService(
      environment: {
        'HOME': temp.path,
        'MAPRISMA_DESKTOP': 'generic',
        'LANG': 'de_DE.UTF-8',
      },
    );
  });
  tearDown(() => temp.deleteSync(recursive: true));
  test(
    'settings preserve unknown large integers and reject malformed numeric keys',
    () {
      final huge = '1${'0' * 80}';
      core.settings.posix.atomicWrite(
        core.identity.settingsPath,
        utf8.encode('{"future":$huge,"quoted":"$huge"}'),
      );
      core.settings.update({
        'values': {'map_light_fps': 30},
      });
      final bytes = File(core.identity.settingsPath).readAsStringSync();
      expect(bytes, contains('"future": $huge'));
      expect(bytes, contains('"quoted": "$huge"'));
      core.settings.posix.atomicWrite(
        core.identity.settingsPath,
        utf8.encode('{$huge:1}'),
      );
      expect(core.settings.load(), isEmpty);
    },
  );
  test('schema defaults have declared shapes and fresh mutable defaults', () {
    for (final entry in defaults.entries) {
      if (entry.value != null) {
        expect(
          core.settings.valid(entry.key, entry.value),
          true,
          reason: entry.key,
        );
      }
    }
    final first = core.settings.value({}, 'details_open') as List;
    first.add('changed');
    expect(core.settings.value({}, 'details_open'), isEmpty);
    expect(core.settings.value({'map_zoom': 'big'}, 'map_zoom'), 1.0);
    expect(
      core.settings.value({'terminal_tabs': 'yes'}, 'terminal_tabs'),
      true,
    );
    expect(
      core.settings.value({
        'window_size': [800],
      }, 'window_size'),
      null,
    );
    expect(core.settings.value({'map_zoom': 1.5}, 'map_zoom'), 1.5);
    expect(
      core.settings.value({'terminal_tabs': false}, 'terminal_tabs'),
      false,
    );
    expect(
      core.settings.value({
        'window_size': [1200, 800],
      }, 'window_size'),
      [1200, 800],
    );
  });
  test('settings UTF-8 write overflow preserves original bytes', () {
    final prefix = '{"unknown":"';
    final source =
        '$prefix${'é' * ((settingsMaxBytes - prefix.length - 2) ~/ 2)}"}';
    final before = utf8.encode(source);
    core.settings.posix.atomicWrite(core.identity.settingsPath, before);
    expect(
      () => core.settings.update({
        'values': {'language': 'pl'},
      }),
      throwsA(isA<FileSystemException>()),
    );
    expect(File(core.identity.settingsPath).readAsBytesSync(), before);
  });
  test(
    'migration renames, drops retired keys and preserves explicit animation',
    () {
      core.settings.posix.atomicWrite(
        core.identity.settingsPath,
        utf8.encode(
          '{"animate_lines":false,"hidden_nodes":["x"],"sidebar_width":360,"map_zoom":1.2}',
        ),
      );
      core.settings.migrate();
      expect(core.settings.load(), {'map_animations': 'off', 'map_zoom': 1.2});
      core.settings.posix.atomicWrite(
        core.identity.settingsPath,
        utf8.encode('{"animate_lines":false,"map_animations":"agents"}'),
      );
      core.settings.migrate();
      expect(core.settings.load(), {'map_animations': 'agents'});
    },
  );
  test('symlinked config and home-like ancestors succeed', () {
    final home = Directory('${temp.path}/var/home/user')
      ..createSync(recursive: true);
    Link('${temp.path}/home').createSync('${temp.path}/var/home');
    final config = Directory('${temp.path}/configs')..createSync();
    Link('${home.path}/.config').createSync(config.path);
    Posix().atomicWrite(
      '${temp.path}/home/user/.config/maprisma/settings.json',
      [1],
    );
    expect(File('${config.path}/maprisma/settings.json').readAsBytesSync(), [
      1,
    ]);
  });
  test(
    'untrusted writable and hidden intermediate directories refuse links',
    () {
      final unsafe = Directory('${temp.path}/unsafe')..createSync();
      final posix = Posix();
      final fd = posix.openAt(-100, unsafe.path, Posix.directory);
      try {
        posix.chmod(fd, 0x1ff);
      } finally {
        posix.close(fd);
      }
      final safe = Directory('${temp.path}/safe')..createSync();
      Link('${unsafe.path}/link').createSync(safe.path);
      Link('${temp.path}/alias').createSync('${unsafe.path}/link');
      for (final parent in [
        unsafe.path,
        '${unsafe.path}/link',
        '${temp.path}/alias',
      ]) {
        expect(
          () => posix.atomicWrite('$parent/x.json', [1]),
          throwsA(isA<FileSystemException>()),
        );
      }
      expect(safe.listSync(), isEmpty);
    },
  );
  test('foreign-owned directories refuse writes even if sticky', () {
    expect(
      () => _ForeignOwnerPosix().atomicWrite('${temp.path}/x.json', [1]),
      throwsA(isA<FileSystemException>()),
    );
    expect(temp.listSync(), isEmpty);
  });
  test('swap between resolution and pinned walk fails closed', () {
    final chosen = Directory('${temp.path}/chosen')..createSync();
    final outside = Directory('${temp.path}/outside')..createSync();
    final posix = _SwapPosix(chosen.path, outside.path);
    expect(
      () => posix.atomicWrite('${chosen.path}/x.json', [1]),
      throwsA(isA<FileSystemException>()),
    );
    expect(outside.listSync(), isEmpty);
    expect(Directory('${chosen.path}-old').listSync(), isEmpty);
  });
  test('identity uses absolute XDG paths, ignores relative overrides', () {
    expect(core.identity.appId, 'com.maprisma.Maprisma');
    final id = AppIdentity(
      environment: {
        'HOME': temp.path,
        'XDG_CONFIG_HOME': 'relative',
        'XDG_CACHE_HOME': '/tmp/cache',
      },
    );
    expect(id.configDir, '${temp.path}/.config/maprisma');
    expect(id.cacheDir, '/tmp/cache/maprisma');
  });
  test(
    'defaults; strict atomic validation; nullable deletion; unknown keys retained',
    () {
      expect(core.settings.snapshot()['map_light_fps'], 20);
      expect(core.settings.snapshot()['system_map_columns'], [
        'pc',
        'disks',
        'programs',
        'tools',
        'folders',
      ]);
      core.dispatch('settings.update', {
        'values': {
          'system_map_columns': ['pc', 'folders'],
        },
      });
      expect(core.settings.snapshot()['system_map_columns'], ['pc', 'folders']);
      expect(core.settings.snapshot()['screenshot_key'], isTrue);
      core.dispatch('settings.update', {
        'values': {'screenshot_key': false},
      });
      expect(core.settings.snapshot()['screenshot_key'], isFalse);
      core.settings.posix.atomicWrite(
        core.identity.settingsPath,
        utf8.encode(
          '{"oracle_unknown":"keep","agent_project_history":{"x":["a"]}}',
        ),
      );
      final before = File(core.identity.settingsPath).readAsBytesSync();
      for (final value in [null, true, 20.0, '20', 25]) {
        expect(
          () => core.dispatch('settings.update', {
            'values': {'language': 'fr', 'map_light_fps': value},
          }),
          throwsFormatException,
        );
        expect(File(core.identity.settingsPath).readAsBytesSync(), before);
      }
      core.dispatch('settings.update', {
        'values': {
          'flutter_theme_mode': 'dark',
          'map_light_fps': 60,
          'language': 'pl',
        },
      });
      expect(core.settings.load()['oracle_unknown'], 'keep');
      expect(core.settings.snapshot()['flutter_theme_mode'], 'dark');
      core.dispatch('settings.update', {
        'values': {'addons_online': null},
      });
      expect(core.settings.snapshot()['addons_online'], true);
      expect(core.i18n.language, 'pl');
      final fd = Posix().openAt(
        -100,
        core.identity.settingsPath,
        Posix.noFollow,
      );
      try {
        expect(Posix().stat(fd).mode & 0x1ff, 0x180);
      } finally {
        Posix().close(fd);
      }
    },
  );
  test(
    'schema and layout reject malformed, huge, duplicate and nonfinite data',
    () {
      for (final params in [
        {},
        {'values': {}},
        {
          'values': {'unknown': 1},
        },
        {
          'values': {'language': null},
        },
        {
          'values': {'map_layers': null},
        },
        {
          'values': {'system_map_columns': null},
        },
        {
          'values': {
            'system_map_columns': ['bogus'],
          },
        },
        {
          'values': {'agent_folder': 'relative'},
        },
      ]) {
        expect(
          () => core.dispatch(
            'settings.update',
            Map<String, dynamic>.from(params),
          ),
          throwsFormatException,
        );
      }
      for (final value in [
        [],
        {'cards': null},
        {
          'cards': {
            'x': [1, true],
          },
        },
        {
          'cards': {
            'x': [double.nan, 1],
          },
        },
        {
          'pins': ['x', 'x'],
        },
        {
          'pins': ['\x00'],
        },
        {'extra': 1},
      ]) {
        expect(validLayout(value), false);
      }
      expect(
        validLayout({
          'cards': {
            'x': [1, 2.5],
          },
          'pins': ['x'],
        }),
        true,
      );
      expect(
        validLayout({'pins': List.generate(20, (i) => '${'é' * 8000}$i')}),
        false,
      );
    },
  );
  test('bounded protocol errors are private and recover', () {
    Map reply(String frame) => jsonDecode(core.handle(frame)) as Map;
    for (final value in [
      [],
      {'id': true},
      {'id': 1, 'protocol': true, 'method': 'settings.get'},
      {'id': 1, 'protocol': 1, 'method': 'settings.get'},
      {'id': 1, 'protocol': 2, 'method': 'settings.get', 'params': []},
    ]) {
      expect(reply(jsonEncode(value))['error']['code'], 'invalid_request');
    }
    expect(reply('x' * 65536)['error']['code'], 'request_too_large');
    expect(reply('{')['error']['code'], 'invalid_request');
    expect(
      reply(
        jsonEncode({'id': 5, 'protocol': 2, 'method': 'settings.get'}),
      )['result']['map_light_fps'],
      20,
    );
    expect(
      reply(
        jsonEncode({'id': 5, 'protocol': 2, 'method': 'shell.exec'}),
      )['error']['code'],
      'unported_route',
    );
  });
  test('i18n uses environment precedence and refreshes saved language', () {
    expect(core.i18n.language, 'de');
    expect(core.i18n.text('Unknown text'), 'Unknown text');
    expect(core.i18n.text('Maprisma'), 'Maprisma');
    expect(core.i18n.plural('one', 'many', 2), 'many');
    core.settings.update({
      'values': {'language': 'fr'},
    });
    expect(core.i18n.language, 'fr');
    final id = AppIdentity(
      environment: {'LC_ALL': 'C', 'LC_MESSAGES': 'pl_PL', 'LANG': 'de_DE'},
    );
    expect(
      ServiceI18n(
        id,
        SettingsStore(AppIdentity(environment: {'HOME': '${temp.path}/other'})),
      ).systemLanguage(),
      'pl',
    );
  });
  test(
    'settings reads refuse symlinks, FIFO, malformed and oversized files',
    () {
      Directory(core.identity.configDir).createSync(recursive: true);
      final outside = File('${temp.path}/outside')
        ..writeAsStringSync('{"language":"pl"}');
      Link(core.identity.settingsPath).createSync(outside.path);
      expect(core.settings.load(), isEmpty);
      core.settings.update({
        'values': {'map_light_fps': 30},
      });
      expect(outside.readAsStringSync(), '{"language":"pl"}');
      expect(
        FileSystemEntity.typeSync(
          core.identity.settingsPath,
          followLinks: false,
        ),
        FileSystemEntityType.file,
      );
      File(
        core.identity.settingsPath,
      ).writeAsStringSync('x' * (settingsMaxBytes + 1));
      expect(core.settings.load(), isEmpty);
      File(core.identity.settingsPath).deleteSync();
      expect(
        Process.runSync('/usr/bin/mkfifo', [
          core.identity.settingsPath,
        ]).exitCode,
        0,
      );
      expect(core.settings.load(), isEmpty);
    },
  );
  test(
    'atomic writes allow trusted ancestor symlink and leave no temporary files',
    () {
      final outside = Directory('${temp.path}/outside')..createSync();
      Link('${temp.path}/link').createSync(outside.path);
      Posix().atomicWrite('${temp.path}/link/settings.json', [1]);
      expect(File('${outside.path}/settings.json').readAsBytesSync(), [1]);
      core.settings.update({
        'values': {'language': 'nl'},
      });
      // The settings and their lock (kept on purpose: flock), nothing else.
      expect(
        {
          for (final e in Directory(core.identity.configDir).listSync())
            e.uri.pathSegments.last,
        },
        {'settings.json', 'settings.json.lock'},
      );
    },
  );
  test('openat pins directory and nofollow resists final symlink swap', () {
    final dir = Directory('${temp.path}/dir')..createSync();
    final file = File('${dir.path}/item')..writeAsStringSync('safe');
    final posix = Posix();
    final fd = posix.openAt(-100, file.path, Posix.noFollow);
    try {
      file.deleteSync();
      final secret = File('${temp.path}/target')
        ..writeAsStringSync('untouched');
      Link(file.path).createSync(secret.path);
      expect(utf8.decode(posix.readDescriptor(fd, 32)), 'safe');
      expect(
        () => posix.readRegular(file.path, 32),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      posix.close(fd);
    }
  });
  test(
    'pidfd checks start-time and UID and never signals mismatched identity',
    () async {
      final child = await Process.start('/usr/bin/sleep', ['30']);
      try {
        final stat = File('/proc/${child.pid}/stat').readAsStringSync();
        final start = stat.substring(stat.lastIndexOf(')') + 2).split(' ')[19];
        final posix = Posix();
        expect(
          posix.signalOwned(
            child.pid,
            '${BigInt.parse(start) + BigInt.one}',
            15,
          ),
          false,
        );
        expect(posix.signalOwned(child.pid, start, 0), true);
        expect(posix.signalOwned(child.pid, start, 15), true);
        await child.exitCode;
        expect(posix.signalOwned(child.pid, start, 0), false);
        expect(posix.signalOwned(-1, start, 15), false);
      } finally {
        child.kill();
      }
    },
  );
  test(
    'theme bounded TOML filtering, nested tables, look gating, bad syntax',
    () {
      final env = {'HOME': temp.path, 'MAPRISMA_DESKTOP': 'omarchy'};
      final c = CoreService(environment: env);
      final file = File('${c.desktop.themeDir}/colors.toml');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        'background = "#112233"\nforeground = "#aBcDeF"\ninvalid = "red"\nnumber = 7\n[nested]\naccent = "#123456"\n',
      );
      expect(c.dispatch('app.theme', {}), {
        'theme': {'background': '#112233', 'foreground': '#aBcDeF'},
      });
      file.writeAsStringSync('not valid toml [');
      expect(c.dispatch('app.theme', {}), {'theme': {}});
      file.writeAsStringSync('x' * (256 * 1024 + 1));
      expect(c.dispatch('app.theme', {}), {'theme': {}});
    },
  );
}

class _SwapPosix extends Posix {
  _SwapPosix(this.chosen, this.outside);
  final String chosen, outside;
  @override
  String resolveParent(String absolute) {
    final result = super.resolveParent(absolute);
    Directory(chosen).renameSync('$chosen-old');
    Link(chosen).createSync(outside);
    return result;
  }
}

class _ForeignOwnerPosix extends Posix {
  @override
  ({int mode, int uid, int size}) stat(int fd) {
    final info = super.stat(fd);
    return (mode: info.mode | 0x200, uid: uid + 12345, size: info.size);
  }
}
