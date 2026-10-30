import 'package:maprisma_core/src/identity.dart';
import 'package:test/test.dart';

/// The app's folder is the bundle, also for the core's helper in bundle/lib:
/// both find the add-ons and manuals the package brings.
void main() {
  test('the bundle, from the app and from its helper', () {
    expect(appFolder('/usr/lib/maprisma/maprisma'), '/usr/lib/maprisma');
    expect(
      appFolder('/usr/lib/maprisma/lib/maprisma-core'),
      '/usr/lib/maprisma',
    );
    expect(appFolder('/home/u/bin/maprisma-core'), '/home/u/bin'); // not in lib
    expect(appFolder('/opt/x/lib/other'), '/opt/x/lib');
  });
}
