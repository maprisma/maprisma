import 'dart:io';
import 'package:path/path.dart' as p;

final class AppIdentity {
  AppIdentity({Map<String, String>? environment})
    : environment = Map.unmodifiable(environment ?? Platform.environment);
  final Map<String, String> environment;
  String get home => environment['HOME'] ?? '/';
  String get name => 'Asterism';
  String get appId => 'io.github.ubruckhaus.Asterism';
  String get shortName => 'asterism';
  String root(String key, String fallback) {
    final value = environment[key] ?? '';
    return value.isNotEmpty && p.isAbsolute(value)
        ? value
        : p.join(home, fallback);
  }

  String get configDir => p.join(root('XDG_CONFIG_HOME', '.config'), shortName);
  String get cacheDir => p.join(root('XDG_CACHE_HOME', '.cache'), shortName);
  String get settingsPath => p.join(configDir, 'settings.json');
}
