import 'dart:convert';
import 'dart:io';
import 'package:maprisma_core/maprisma_core.dart';
import 'package:test/test.dart';

/// addons.enable_found (task 055): at the start everything found on this PC
/// gets its add-on switched on, except one the user switched off.
/// Uses the signed add-ons of an installed Maprisma (skipped without them).
void main() {
  const signed = '/usr/lib/maprisma/addons';
  final skip =
      Directory('$signed/providers-online').existsSync() &&
          Directory('$signed/llm-ollama').existsSync()
      ? false
      : 'no installed Maprisma add-ons';
  late Directory temp;
  late Map<String, String> env;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('maprisma-enable-found-');
    final user = Directory('${temp.path}/.local/share/maprisma/addons')
      ..createSync(recursive: true);
    for (final id in ['providers-online', 'llm-ollama']) {
      if (!Directory('$signed/$id').existsSync()) continue;
      Process.runSync('cp', ['-r', '$signed/$id', user.path]);
    }
    env = {
      'HOME': temp.path,
      'MAPRISMA_DESKTOP': 'generic',
      'PATH': '${temp.path}/bin',
      'LANG': 'en_US.UTF-8',
    };
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> saved() =>
      jsonDecode(
            File(
              '${temp.path}/.config/maprisma/settings.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('found add-ons are switched on, the ones switched off stay off', () {
    final core = CoreService(environment: env);
    final first = core.dispatch('addons.enable_found', {
      'ids': ['providers-online', 'llm-ollama', 'not-here'],
    });
    expect(first['switched_on'], ['llm-ollama', 'providers-online']);
    expect(saved()['addons_enabled'], ['llm-ollama', 'providers-online']);
    // Nothing new: nothing changes.
    expect(
      core.dispatch('addons.enable_found', {
        'ids': ['providers-online'],
      })['switched_on'],
      isEmpty,
    );

    // Switched off by the user: remembered, not switched on again.
    core.dispatch('addons.set_enabled', {
      'id': 'providers-online',
      'enabled': false,
    });
    expect(saved()['addons_off'], ['providers-online']);
    expect(
      core.dispatch('addons.enable_found', {
        'ids': ['providers-online', 'llm-ollama'],
      })['switched_on'],
      isEmpty,
    );
    expect(saved()['addons_enabled'], ['llm-ollama']);

    // Switched on again by the user: no longer remembered as off.
    core.dispatch('addons.set_enabled', {
      'id': 'providers-online',
      'enabled': true,
    });
    expect(saved()['addons_off'], isEmpty);
  }, skip: skip);

  test('setup: a found add-on left unticked counts as switched off', () {
    final core = CoreService(environment: env);
    core.dispatch('setup.apply', {
      'enabled': ['llm-ollama'],
      'declined': ['providers-online'],
    });
    expect(saved()['addons_off'], ['providers-online']);
    expect(
      core.dispatch('addons.enable_found', {
        'ids': ['providers-online'],
      })['switched_on'],
      isEmpty,
    );
    // Ticked later in setup: on, and no longer off.
    core.dispatch('setup.apply', {
      'enabled': ['llm-ollama', 'providers-online'],
    });
    expect(saved()['addons_off'], isEmpty);
    expect(saved()['addons_enabled'], ['llm-ollama', 'providers-online']);
  }, skip: skip);

  test('a malformed request changes nothing', () {
    final core = CoreService(environment: env);
    for (final params in [
      <String, dynamic>{},
      {'ids': 'providers-online'},
      {
        'ids': [1],
      },
      {
        'ids': ['providers-online'],
        'more': true,
      },
    ]) {
      expect(
        () => core.dispatch('addons.enable_found', params),
        throwsA(anything),
      );
    }
    expect(
      () => core.dispatch('setup.apply', {
        'enabled': ['llm-ollama'],
        'declined': 'providers-online',
      }),
      throwsA(anything),
    );
  });
}
