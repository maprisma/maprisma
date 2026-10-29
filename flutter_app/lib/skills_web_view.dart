import 'package:flutter/material.dart';

/// Skills from the web (skills.web_search, skills.web_fetch): a skills.sh
/// search, one skill's files fetched (nothing of it runs), then the folder it
/// goes into and the agents that get it; the preview is skills.web_preview.
class SkillsWebView extends StatefulWidget {
  const SkillsWebView({
    super.key,
    required this.busy,
    required this.tr,
    required this.run,
    required this.onPreview,
    required this.onClose,
  });
  final bool busy;
  final String Function(String) tr;
  final Future<Map<String, dynamic>> Function(
    String method,
    Map<String, dynamic> params,
  )
  run;
  final Future<void> Function(Map<String, dynamic> params) onPreview;
  final VoidCallback onClose;

  @override
  State<SkillsWebView> createState() => _SkillsWebViewState();
}

class _SkillsWebViewState extends State<SkillsWebView> {
  final _query = TextEditingController();
  List<Map<String, dynamic>>? _found;
  Map<String, dynamic>? _skill;
  String? _status, _error;
  bool _loading = false;
  String? _folder;
  final _chosen = <String>{};

  String tr(String key) => widget.tr(key);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _skill = null;
    });
    try {
      final result = await widget.run('skills.web_search', {'query': query});
      if (mounted) {
        setState(
          () =>
              _found = (result['skills'] as List).cast<Map<String, dynamic>>(),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = tr('Search failed: {0}').replaceAll('{0}', '').trim(),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _fetch(Map<String, dynamic> skill) async {
    setState(() {
      _loading = true;
      _error = null;
      _skill = null;
      _status = tr(
        'Fetching the file list of {0}…',
      ).replaceAll('{0}', '${skill['name']}');
    });
    try {
      final fetched = await widget.run('skills.web_fetch', {
        'repo': skill['repo'],
        'skill_id': skill['skill_id'],
        'name': skill['name'],
      });
      if (!mounted) return;
      setState(() {
        _skill = fetched;
        _status = null;
        _folder = (fetched['targets'] as List).first as String;
        _chosen.clear();
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _status = null;
          _error = tr(
            'Could not fetch {0}: {1}',
          ).replaceAll('{0}', '${skill['name']}').replaceAll('{1}', '').trim();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final skill = _skill;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(tr('Add skills'), style: text.titleLarge)),
                IconButton(
                  tooltip: tr('Close'),
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(tr('Skills teach your agents how to do a task.')),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('skills-web-search'),
              controller: _query,
              decoration: InputDecoration(
                labelText: tr('Search the web'),
                hintText: tr('e.g. pdf, docker, testing'),
                prefixIcon: const Icon(Icons.search),
              ),
              onSubmitted: _loading ? null : (_) => _search(),
            ),
            if (_found != null && _found!.isEmpty) Text(tr('No skill found.')),
            if (skill == null)
              for (final found in _found ?? const <Map<String, dynamic>>[])
                ListTile(
                  key: ValueKey('skill-${found['repo']}/${found['skill_id']}'),
                  title: Text('${found['name']}'),
                  subtitle: Text('github.com/${found['repo']}'),
                  trailing: (found['installs'] as int? ?? 0) > 0
                      ? Text('${found['installs']}')
                      : null,
                  onTap: widget.busy || _loading ? null : () => _fetch(found),
                ),
            if (skill != null) ..._details(context, skill),
            if (_status != null) Text(_status!),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _details(BuildContext context, Map<String, dynamic> skill) {
    final scripts = (skill['scripts'] as List).cast<String>();
    final targets = (skill['targets'] as List).cast<String>();
    final agents = (skill['agents'] as List).cast<Map>();
    return [
      const SizedBox(height: 12),
      Row(
        children: [
          IconButton(
            tooltip: tr('Back'),
            onPressed: () => setState(() => _skill = null),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: SelectableText(
              '${skill['name']} · github.com/${skill['repo']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        ],
      ),
      if ('${skill['description']}'.isNotEmpty)
        SelectableText('${skill['description']}'),
      Text('${tr('Files')}: ${(skill['files'] as List).length}'),
      if (scripts.isNotEmpty)
        Text(
          '${tr('Skills may include scripts that agents can run.')} ${scripts.take(6).join(', ')}',
          style: TextStyle(color: Theme.of(context).colorScheme.tertiary),
        ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: const ValueKey('skills-web-into'),
        initialValue: _folder,
        decoration: InputDecoration(labelText: tr('Into')),
        items: [
          for (final t in targets) DropdownMenuItem(value: t, child: Text(t)),
        ],
        onChanged: (v) => setState(() => _folder = v),
      ),
      const SizedBox(height: 8),
      Text(tr('Also for')),
      Text(tr('Agents that do not read this folder yet get it too.')),
      for (final agent in agents)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${agent['name']}'),
          value: _chosen.contains(agent['command']),
          onChanged: (on) => setState(() {
            on == true
                ? _chosen.add(agent['command'] as String)
                : _chosen.remove(agent['command']);
          }),
        ),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: widget.busy || _folder == null
              ? null
              : () => widget.onPreview({
                  'fetched': skill['fetched'],
                  'folder': _folder,
                  'agents': [
                    for (final a in agents)
                      if (_chosen.contains(a['command'])) a['command'],
                  ],
                }),
          child: Text(tr('Preview')),
        ),
      ),
    ];
  }
}
