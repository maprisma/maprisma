import 'package:flutter/material.dart';

String _when(dynamic checked) => '${checked ?? ''}'
    .replaceFirst('T', ' ')
    .padRight(16)
    .substring(0, 16)
    .trim();

/// The tools (and prompts) a server said it offers, or why it did not answer
/// (an mcp_tools answer: status, checked, tools, prompts, server, error).
class McpToolsResult extends StatelessWidget {
  const McpToolsResult({super.key, required this.answer, required this.tr});
  final Map<String, dynamic> answer;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final ok = answer['status'] == 'ok';
    final tools = (answer['tools'] as List? ?? const []).cast<Map>();
    final prompts = (answer['prompts'] as List? ?? const []).cast<Map>();
    final summary = ok
        ? [
            '${tools.length} ${tr('Tools')}',
            if ('${answer['server'] ?? ''}'.isNotEmpty) '${answer['server']}',
          ].join(' · ')
        : '${answer['error'] ?? ''}';
    final line = answer['checked'] == null
        ? (ok ? summary : tr('Does not answer: {0}').replaceAll('{0}', summary))
        : tr('Asked on {0}: {1}')
              .replaceAll('{0}', _when(answer['checked']))
              .replaceAll('{1}', summary);
    Widget list(List<Map> items) => Column(
      children: [
        for (final item in items)
          ListTile(
            dense: true,
            title: SelectableText('${item['name']}'),
            subtitle: Text(
              '${item['description']}'.isEmpty ? '—' : '${item['description']}',
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          line,
          style: ok
              ? null
              : TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        if (ok) list(tools),
        if (ok && prompts.isNotEmpty) ...[
          Text(tr('Prompts'), style: Theme.of(context).textTheme.titleSmall),
          list(prompts),
        ],
      ],
    );
  }
}

/// A set-up server's tools: the last answer kept, and Ask the server, which
/// starts its program once (as an agent does) and stops it again.
class McpServerTools extends StatefulWidget {
  const McpServerTools({
    super.key,
    required this.name,
    required this.busy,
    required this.tr,
    required this.call,
    required this.run,
  });
  final String name;
  final bool busy;
  final String Function(String) tr;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) run;

  @override
  State<McpServerTools> createState() => _McpServerToolsState();
}

class _McpServerToolsState extends State<McpServerTools> {
  Map<String, dynamic>? _known;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _loadKept();
  }

  Future<void> _loadKept() async {
    try {
      final reply = await widget.call('mcp.tools_cached', {
        'name': widget.name,
      });
      if (mounted) {
        setState(() => _known = reply['cached'] as Map<String, dynamic>?);
      }
    } catch (_) {
      // Shown as not asked yet.
    }
  }

  Future<void> _ask() async {
    setState(() => _asking = true);
    try {
      final answer = await widget.run('mcp.tools', {'name': widget.name});
      if (mounted) setState(() => _known = answer);
    } catch (_) {
      if (mounted) {
        setState(
          () => _known = {
            'status': 'failed',
            'error': widget
                .tr('Search failed: {0}')
                .replaceAll('{0}', '')
                .trim(),
          },
        );
      }
    } finally {
      if (mounted) setState(() => _asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = widget.tr;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('Tools'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                key: ValueKey('mcp-ask-${widget.name}'),
                onPressed: widget.busy || _asking ? null : _ask,
                child: Text(
                  tr(_known == null ? 'Ask the server' : 'Ask again'),
                ),
              ),
            ],
          ),
          if (_asking)
            Text(tr('Asking the server…'))
          else if (_known == null)
            Text(
              tr(
                'Not asked yet. Asking starts the server once (like an agent does) and stops it again.',
              ),
            )
          else
            McpToolsResult(answer: _known!, tr: tr),
        ],
      ),
    );
  }
}
