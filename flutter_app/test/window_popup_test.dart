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
}
