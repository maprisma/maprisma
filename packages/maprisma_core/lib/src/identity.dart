import 'dart:io';
import 'package:path/path.dart' as p;

final class AppIdentity {
  AppIdentity({Map<String, String>? environment})
    : environment = Map.unmodifiable(environment ?? Platform.environment);
  final Map<String, String> environment;
  String get home => environment['HOME'] ?? '/';

  /// Maprisma, called Asterism until 2026-10-30 (legacy_move.dart copies
  /// the old folders over once).
  String get name => 'Maprisma';
  String get appId => 'com.maprisma.Maprisma';
  String get shortName => 'maprisma';
  static const legacyShortName = 'asterism';
  String root(String key, String fallback) {
    final value = environment[key] ?? '';
    return value.isNotEmpty && p.isAbsolute(value)
        ? value
        : p.join(home, fallback);
  }

  String get configDir => p.join(root('XDG_CONFIG_HOME', '.config'), shortName);
  String get cacheDir => p.join(root('XDG_CACHE_HOME', '.cache'), shortName);
  String get settingsPath => p.join(configDir, 'settings.json');
  String get dataDir =>
      p.join(root('XDG_DATA_HOME', '.local/share'), shortName);
  String get stateDir =>
      p.join(root('XDG_STATE_HOME', '.local/state'), shortName);
}

/// The installed app's folder (its bundle): the folder of the app's
/// program, also when the core's helper in `bundle/lib` asks, so both find
/// the add-ons and manuals that come with the package (`bundle/addons`,
/// `bundle/data`).
String appFolder([String? executable]) {
  final exe = executable ?? Platform.resolvedExecutable;
  final dir = p.dirname(exe);
  return p.basename(exe) == 'maprisma-core' && p.basename(dir) == 'lib'
      ? p.dirname(dir)
      : dir;
}
