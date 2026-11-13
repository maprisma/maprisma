import 'dart:io';

import 'package:maprisma/window_popup.dart';
import 'package:flutter_test/flutter_test.dart';

/// window_mode: only popup floats; auto is an ordinary window everywhere.
void main() {
  test('which window mode applies', () {
    expect(popupWanted(null, 'omarchy'), isFalse);
    expect(popupWanted('auto', 'omarchy'), isFalse);
    expect(popupWanted('auto', 'generic'), isFalse);
    expect(popupWanted('window', 'omarchy'), isFalse);
    expect(popupWanted('popup', 'omarchy'), isTrue);
    // COSMIC, Plasma or any other desktop: no popup, an ordinary window.
    expect(popupWanted('popup', 'generic'), isFalse);
    expect(popupWanted('popup', ''), isFalse);
    expect(popupAvailable('omarchy'), isTrue);
    expect(popupAvailable('generic'), isFalse);
  });

  test('a file chooser keeps the popup open while it runs', () async {
    expect(PopupGuard.busy, isFalse);
    final seen = await PopupGuard.around(() async => PopupGuard.busy);
    expect(seen, isTrue);
    expect(PopupGuard.busy, isFalse);
  });

  test(
    'Hyprland: XDG_CURRENT_DESKTOP decides; a stale signature needs its socket',
    () {
      final dir = Directory.systemTemp.createTempSync('popup-hypr');
      addTearDown(() => dir.deleteSync(recursive: true));
      final live = {
        'HYPRLAND_INSTANCE_SIGNATURE': 'abc',
        'XDG_RUNTIME_DIR': '${dir.path}/run',
      };
      expect(hyprlandSession({'XDG_CURRENT_DESKTOP': 'Hyprland'}), isTrue);
      expect(hyprlandSession(live), isFalse);
      File('${dir.path}/run/hypr/abc/.socket.sock').createSync(recursive: true);
      expect(hyprlandSession(live), isTrue);
      expect(hyprlandSession({...live, 'XDG_CURRENT_DESKTOP': 'KDE'}), isFalse);
      expect(
        hyprlandSession({...live, 'XDG_CURRENT_DESKTOP': 'COSMIC'}),
        isFalse,
      );
    },
  );
}
