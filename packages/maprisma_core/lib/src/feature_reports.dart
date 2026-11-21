part of 'core.dart';

/// Reports owns its library and pending drafts; the service supplies shared facts.
final class _ReportsFeatureState {
  _ReportsFeatureState(String directory) : library = ReportsLibrary(directory);
  final ReportsLibrary library;
  final drafts = <String, ReportData>{};
}

/// Reports feature entry points. Shared kernel routes stay in CoreService.
extension ReportsFeatureRoutes on CoreService {
  ReportsLibrary get _reports => _reportsFeature.library;
  Map<String, ReportData> get _reportDrafts => _reportsFeature.drafts;

  Adapter? reportAdapter(String command) =>
      addons.adapters.where((a) => a.command == command).firstOrNull;

  Map<String, dynamic> _reportsRoute(String method, ReportData params) {
    void shape(Set<String> keys) {
      if (params.keys.any((k) => !keys.contains(k))) {
        throw const FormatException('Invalid report parameters');
      }
    }

    int id(String field) {
      final value = params[field];
      if (value is! int || value < 1) throw const FormatException('Invalid id');
      return value;
    }

    String? optional(String field, int bound, {bool required = false}) =>
        params.containsKey(field)
        ? reportField(
            params[field],
            bound,
            required: required,
            multiline: field == 'note',
          )
        : null;

    switch (method) {
      case 'reports.helpers':
        shape({});
        final rules = reportRules(identity);
        final helpers = smartHelpers()
            .where(
              (h) =>
                  h['local'] == true ||
                  rules.allowed &&
                      reportRewriteWithoutTools(
                        reportAdapter(h['command'] as String),
                      ),
            )
            .toList();
        final chosen = settings.load()['smart_helper'];
        return {
          'helpers': helpers,
          'chosen': helpers.any((h) => h['command'] == chosen)
              ? chosen
              : helpers.firstOrNull?['command'],
          'online_allowed': rules.allowed,
          'rules_broken': rules.broken,
        };
      case 'reports.generate':
        final filters = reportParameters(params);
        final command = filters['helper'];
        if (!smartHelpers().any((h) => h['command'] == command)) {
          throw ServiceError('no_helper');
        }
        if (command != 'local-helper') {
          if (!reportRewriteWithoutTools(reportAdapter(command as String))) {
            throw ServiceError('no_helper');
          }
          if (!reportRules(identity).allowed) {
            throw ServiceError('online_blocked');
          }
        }
        final log = reads.activityLog;
        if (!log.enabled) throw ServiceError('log_off');
        final (today, keep, from, through) = log.range(filters);
        if (!log
            .retainedRows(today, keep, from, through)
            .any((entry) => matchesReportFilters(entry.$2, filters))) {
          throw ServiceError('no_entries');
        }
        return tasks.startPrivate(
          'reports.generate',
          utf8.encode(
            jsonEncode({'filters': filters, 'language': i18n.language}),
          ),
          (result) {
            if (result.containsKey('code')) return result;
            final id = newHandle();
            _reportDrafts[id] = result;
            if (_reportDrafts.length > 8) {
              _reportDrafts.remove(_reportDrafts.keys.first);
            }
            return {'draft_id': id, 'draft': result};
          },
        );
      case 'reports.save':
        shape({'draft_id', 'title', 'note'});
        final draft = _reportDrafts[params['draft_id']];
        if (draft == null) throw ServiceError('draft_unknown');
        final title = reportField(params['title'], 200, required: true);
        final note = optional('note', 2000);
        final report = _reports.save(draft, title, note == '' ? null : note);
        _reportDrafts.remove(params['draft_id']);
        return {'report': report};
      case 'reports.list':
        shape({'query', 'cursor'});
        return _reports.list(
          optional('query', 200) ?? '',
          params.containsKey('cursor') ? id('cursor') : null,
        );
      case 'reports.get':
        shape({'id'});
        return {'report': _reports.get(id('id'))};
      case 'reports.update':
        shape({'id', 'title', 'note'});
        final title = optional('title', 200, required: true);
        final note = optional('note', 2000);
        if (title == null && note == null) {
          throw const FormatException('Missing changes');
        }
        return {'report': _reports.update(id('id'), title: title, note: note)};
      case 'reports.delete':
        shape({'id'});
        return {'deleted': _reports.delete(id('id'))};
      case 'reports.move_aside':
        shape({});
        return {'moved_to': _reports.moveAside()};
      default:
        throw ServiceError('unported_route');
    }
  }
}
