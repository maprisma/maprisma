import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:maprisma_core/src/identity.dart';
import 'package:maprisma_core/src/settings.dart';
import 'package:test/test.dart';

/// Two writers of the same settings.json at once (the app's core and
/// another process, such as a Devel build next to an installed one): each
/// saves its own key over and over; no save may undo the other's.
void main() {
  test('concurrent saves of different keys are all kept', () async {
    final root = Directory.systemTemp.createTempSync('settings-lock');
    addTearDown(() => root.deleteSync(recursive: true));
    final environment = {
      'HOME': root.path,
      'XDG_CONFIG_HOME': '${root.path}/config',
    };
    const rounds = 150;
    Future<void> writer(String key) => Isolate.run(() {
      final store = SettingsStore(AppIdentity(environment: environment));
      for (var i = 0; i < rounds; i++) {
        store.saveOwn({
          key: {'n': '$i'},
        });
      }
    });
    await Future.wait([writer('agent_projects'), writer('web_source')]);
    final saved =
        jsonDecode(
              File(
                AppIdentity(environment: environment).settingsPath,
              ).readAsStringSync(),
            )
            as Map;
    expect(saved['agent_projects'], {'n': '${rounds - 1}'});
    expect(saved['web_source'], {'n': '${rounds - 1}'});
  });
}
