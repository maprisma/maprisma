import 'package:asterism/window_popup.dart';
import 'package:flutter_test/flutter_test.dart';

/// window_mode: auto is a popup on Omarchy only; popup and window force it.
void main() {
  test('which window mode applies', () {
    expect(popupWanted(null, 'omarchy'), isTrue);
    expect(popupWanted('auto', 'omarchy'), isTrue);
    expect(popupWanted('auto', 'generic'), isFalse);
    expect(popupWanted('window', 'omarchy'), isFalse);
    expect(popupWanted('popup', 'generic'), isTrue);
  });

  test('a file chooser keeps the popup open while it runs', () async {
    expect(PopupGuard.busy, isFalse);
    final seen = await PopupGuard.around(() async => PopupGuard.busy);
    expect(seen, isTrue);
    expect(PopupGuard.busy, isFalse);
  });
}
