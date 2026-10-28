import 'identity.dart';
import 'settings.dart';
import 'core_assets.g.dart';

final class ServiceI18n {
  ServiceI18n(this.identity, this.settings);
  final AppIdentity identity;
  final SettingsStore settings;
  String systemLanguage() {
    for (final key in ['LC_ALL', 'LC_MESSAGES', 'LANG']) {
      final code = (identity.environment[key] ?? '')
          .toLowerCase()
          .replaceAll('-', '_')
          .split(RegExp(r'[_\.@]'))
          .first;
      if (['', 'c', 'posix'].contains(code)) continue;
      return languages.contains(code) ? code : 'en';
    }
    return 'en';
  }

  String get language {
    final saved = settings.load()['language'];
    return saved is String && languages.contains(saved)
        ? saved
        : systemLanguage();
  }

  String _named(String text) => text.replaceAll('AI Agents Map', 'Asterism');
  String text(String key) {
    final value = (serviceTables[language] as Map?)?[key];
    return _named(value is String ? value : key);
  }

  String plural(String one, String other, int n) {
    final lang = language;
    final forms = (serviceTables[lang] as Map?)?['\x04$one'];
    if (forms is! List || forms.isEmpty || !forms.every((f) => f is String)) {
      return _named(n == 1 ? one : other);
    }
    var index = n == 1 ? 0 : forms.length - 1;
    if (lang == 'pl' && forms.length == 3) {
      index = n == 1
          ? 0
          : n % 10 >= 2 && n % 10 <= 4 && !(n % 100 >= 12 && n % 100 <= 14)
          ? 1
          : 2;
    } else if (lang == 'fr' || lang == 'pt') {
      index = n <= 1 ? 0 : forms.length - 1;
    }
    return _named(forms[index] as String);
  }
}
