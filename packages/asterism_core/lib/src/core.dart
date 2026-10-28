import 'dart:convert';
import 'desktop.dart';
import 'identity.dart';
import 'posix_ffi.dart';
import 'protocol.dart';
import 'settings.dart';
import 'service_i18n.dart';

const portedRoutes = {
  'settings.get',
  'settings.update',
  'app.theme',
  'app.identity',
  'desktop.snapshot',
  'i18n.lookup',
};
// Phase 7 removes this blocker only after every route has differential coverage.
const dartCoreComplete = false;

final class CoreService {
  CoreService({Map<String, String>? environment}) {
    identity = AppIdentity(environment: environment);
    settings = SettingsStore(identity);
    settings.migrate();
    desktop = detectDesktop(identity, Posix());
    i18n = ServiceI18n(identity, settings);
  }
  late final AppIdentity identity;
  late final SettingsStore settings;
  late final Desktop desktop;
  late final ServiceI18n i18n;
  Map<String, dynamic> dispatch(String method, Map<String, dynamic> params) {
    if (!portedRoutes.contains(method)) throw ServiceError('unported_route');
    if (method == 'settings.update') return settings.update(params);
    if (method == 'i18n.lookup') {
      if (params.keys.any((k) => !['text', 'other', 'n'].contains(k)) ||
          params['text'] is! String ||
          (params.length != 1 &&
              !(params.length == 3 &&
                  params['other'] is String &&
                  params['n'] is int))) {
        throw const FormatException('Invalid translation');
      }
      return {
        'language': i18n.language,
        'text': params.length == 1
            ? i18n.text(params['text'])
            : i18n.plural(params['text'], params['other'], params['n']),
      };
    }
    if (params.isNotEmpty) throw const FormatException('Unexpected parameters');
    switch (method) {
      case 'settings.get':
        return settings.snapshot();
      case 'app.theme':
        return {
          'theme':
              settings.value(settings.load(), 'look') == 'omarchy' &&
                  desktop.name == 'omarchy'
              ? desktop.themeColors()
              : <String, String>{},
        };
      case 'app.identity':
        return {
          'name': identity.name,
          'app_id': identity.appId,
          'short_name': identity.shortName,
          'config_dir': identity.configDir,
          'cache_dir': identity.cacheDir,
        };
      case 'desktop.snapshot':
        return {'name': desktop.name, 'theme_dir': desktop.themeDir};
    }
    throw ServiceError('unported_route');
  }

  String handle(String frame) {
    int? id;
    Map<String, dynamic> response;
    try {
      // Python reports null for oversized or undecodable frames, and a parsed
      // nonnegative id for later validation failures.
      if (utf8.encode(frame).length + 1 > maxRequest) {
        throw ServiceError('request_too_large');
      }
      final raw = jsonDecode(frame);
      if (raw is Map && raw['id'] is int && raw['id'] >= 0) id = raw['id'];
      final request = Request.decode(frame);
      response = {
        'id': request.id,
        'result': dispatch(request.method, request.params),
      };
    } on ServiceError catch (e) {
      response = {
        'id': id,
        'error': {'code': e.code},
      };
    } on FormatException {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    } on TypeError {
      response = {
        'id': id,
        'error': {'code': 'invalid_request'},
      };
    } catch (_) {
      response = {
        'id': id,
        'error': {'code': 'operation_failed'},
      };
    }
    var result = jsonEncode(response);
    if (utf8.encode(result).length > maxResponse) {
      result = jsonEncode({
        'id': id,
        'error': {'code': 'response_too_large'},
      });
    }
    return result;
  }
}
