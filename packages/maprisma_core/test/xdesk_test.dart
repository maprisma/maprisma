import 'dart:io';

import 'package:maprisma_core/src/desktop.dart' show otherSession;
import 'package:maprisma_core/src/desktop_palette.dart';
import 'package:maprisma_core/src/hyprland.dart' show WindowRounding;
import 'package:test/test.dart';

/// COSMIC and Plasma next to Hyprland: which desktop adapter, and the
/// window corners "Like windows" follows.
void main() {
  test('a COSMIC or Plasma session is never Omarchy', () {
    for (final session in ['COSMIC', 'KDE', 'GNOME:Plasma']) {
      expect(otherSession({'XDG_CURRENT_DESKTOP': session}), isTrue);
    }
    for (final session in ['Hyprland', 'hyprland:omarchy', '', ':']) {
      expect(otherSession({'XDG_CURRENT_DESKTOP': session}), isFalse);
    }
    expect(otherSession({}), isFalse);
  });

  group('desktop corners', () {
    late Directory home;
    setUp(() => home = Directory.systemTemp.createTempSync('xdesk'));
    tearDown(() => home.deleteSync(recursive: true));
    Map<String, String> env(String d) => {
      'HOME': home.path,
      'XDG_CURRENT_DESKTOP': d,
    };
    final none = '/nowhere/cosmic';

    test('COSMIC radius_s from the theme in v2, Plasma 8, else none', () {
      final theme = '${home.path}/.config/cosmic/com.system76.CosmicTheme.Dark';
      File('$theme/v2/corner_radii')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          '(\n    radius_0: (0.0, 0.0, 0.0, 0.0),\n    radius_s: (14.0, 14.0, 14.0, 14.0),\n)',
        );
      Directory('$theme/v1').createSync(); // COSMIC 1.x leaves it empty
      expect(desktopRounding(env('COSMIC'), systemRoot: none), 14);
      File('$theme/v2/corner_radii').deleteSync();
      expect(desktopRounding(env('COSMIC'), systemRoot: none), 8);
      expect(desktopRounding(env('KDE'), systemRoot: none), 8);
      expect(desktopRounding(env('GNOME'), systemRoot: none), isNull);
      expect(desktopRounding({'HOME': home.path}, systemRoot: none), isNull);
    });

    test('off Hyprland the route reports the desktop corners', () {
      expect(WindowRounding(env('KDE')).value, 8);
      expect(WindowRounding({'HOME': home.path}).value, isNull);
    });
  });

  test('cosmicConfig: user v2, user v1, then the system', () {
    final home = Directory.systemTemp.createTempSync('xdesk');
    addTearDown(() => home.deleteSync(recursive: true));
    final system = '${home.path}/system';
    File('$system/C/v1/k')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('system');
    expect(cosmicConfig(home.path, 'C', 'k', systemRoot: system), 'system');
    File('${home.path}/cosmic/C/v1/k')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('v1');
    expect(cosmicConfig(home.path, 'C', 'k', systemRoot: system), 'v1');
    File('${home.path}/cosmic/C/v2/k')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('v2');
    expect(cosmicConfig(home.path, 'C', 'k', systemRoot: system), 'v2');
  });
}
