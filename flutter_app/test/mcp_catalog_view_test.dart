import 'package:maprisma/mcp_catalog_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _option(
  String handle,
  String kind, {
  bool runnable = true,
  List<Map<String, dynamic>> needs = const [],
  List<String> onCommandLine = const [],
}) => {
  'option': handle,
  'kind': kind,
  'label': kind == 'remote' ? 'remote · api.example' : '$kind · pkg 1.0',
  'runnable': runnable,
  'command': kind == 'npm' ? 'npx' : (kind == 'pypi' ? 'uvx' : ''),
  'args': [],
  'env': [],
  'url': '',
  'headers': [],
  'needs': needs,
  'on_command_line': onCommandLine,
};

Map<String, dynamic> _need(
  String name, {
  bool required = false,
  bool secret = false,
  String description = '',
}) => {
  'name': name,
  'description': description,
  'required': required,
  'secret': secret,
  'value': '',
  'hint': '',
};

Map<String, dynamic> _server(
  String short,
  List<Map<String, dynamic>> options, {
  String name = '',
}) => {
  'name': name.isEmpty ? short : name,
  'short': short,
  'title': '',
  'description': 'About $short',
  'version': '1.0',
  'repository': 'https://github.com/x/$short',
  'website': '',
  'updated': '',
  'status': '',
  'publisher': {'kind': 'github', 'who': 'someone'},
  'options': options,
};

final _catalog = {
  'groups': [
    {'key': 'files', 'label': 'Files and data'},
    {'key': 'code', 'label': 'Coding'},
  ],
  'picks': [
    {
      'key': 'filesystem',
      'title': 'Filesystem',
      'group': 'files',
      'maker': 'MCP project',
      'trust': 'Reference server · MCP project',
      'trust_hint': 'Written by the people behind MCP.',
      'about': 'Reads files in one folder.',
      'tries': ['Sort my PDFs'],
      'needs': 'A folder the agents may use.',
      'repository': 'https://github.com/modelcontextprotocol/servers',
      'key_url': '',
      'server': _server('filesystem', [
        _option(
          'h-fs',
          'npm',
          needs: [_need('arg:0', required: true, description: 'Folder')],
        ),
      ]),
    },
    {
      'key': 'github',
      'title': 'GitHub',
      'group': 'code',
      'maker': 'GitHub',
      'trust': 'Official · GitHub',
      'trust_hint': 'Made by the company.',
      'about': 'Works with GitHub.',
      'tries': [],
      'needs': 'A token.',
      'repository': 'https://github.com/github/github-mcp-server',
      'key_url': 'https://github.com/settings/personal-access-tokens',
      'server': _server('github', [
        _option('h-gh-npm', 'npm', runnable: false),
        _option(
          'h-gh',
          'remote',
          needs: [_need('GITHUB_TOKEN', required: true, secret: true)],
        ),
      ]),
    },
  ],
};

void main() {
  final agents = [
    {'command': 'claude', 'name': 'Claude Code', 'mcp': true},
    {'command': 'codex', 'name': 'Codex', 'mcp': true},
    {'command': 'nomcp', 'name': 'No MCP', 'mcp': false},
  ];

  Future<(List<(String, Map)>, List<Map<String, dynamic>>)> pump(
    WidgetTester tester, {
    Map<String, dynamic> Function(Map params)? search,
  }) async {
    final calls = <(String, Map)>[];
    final previews = <Map<String, dynamic>>[];
    await tester.binding.setSurfaceSize(const Size(900, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: McpCatalogView(
              agents: agents,
              busy: false,
              tr: (key) => key,
              run: (method, params) async {
                calls.add((method, params));
                if (method == 'mcp.catalog') return _catalog;
                if (method == 'mcp.option_test') {
                  return {
                    'status': 'ok',
                    'server': 'fs 1',
                    'tools': [
                      {'name': 'read_file', 'description': 'Reads'},
                    ],
                    'prompts': [],
                  };
                }
                return search!(params);
              },
              onPreview: (params) async => previews.add(params),
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (calls, previews);
  }

  testWidgets('a recommended server is filled in and previewed', (
    tester,
  ) async {
    final (calls, previews) = await pump(tester);
    expect(calls.single.$1, 'mcp.catalog');
    expect(find.text('Files and data'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-pick-filesystem')));
    await tester.pumpAndSettle();
    expect(find.text('Reference server · MCP project'), findsOneWidget);
    expect(find.text('Needs: A folder the agents may use.'), findsOneWidget);
    final preview = find.widgetWithText(FilledButton, 'Preview');
    expect(tester.widget<FilledButton>(preview).onPressed, isNull);
    expect(find.text('Fill in: Folder'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mcp-need-arg:0')),
      '~/Documents',
    );
    await tester.pump();
    // Only agents that take MCP servers, all ticked.
    expect(find.text('No MCP'), findsNothing);
    await tester.tap(find.text('Codex'));
    await tester.pump();
    final test = find.byKey(const ValueKey('mcp-catalog-test'));
    await tester.tap(test);
    await tester.pumpAndSettle();
    expect(calls.last.$1, 'mcp.option_test');
    expect(calls.last.$2, {
      'option': 'h-fs',
      'values': {'arg:0': '~/Documents'},
    });
    expect(find.text('1 Tools · fs 1'), findsOneWidget);
    expect(find.text('read_file'), findsOneWidget);
    await tester.tap(preview);
    await tester.pump();
    expect(previews.single, {
      'option': 'h-fs',
      'name': 'filesystem',
      'values': {'arg:0': '~/Documents'},
      'agents': ['claude'],
    });
  });

  testWidgets('the runnable way is chosen; a secret field is hidden', (
    tester,
  ) async {
    final (_, previews) = await pump(tester);
    await tester.tap(find.byKey(const ValueKey('mcp-pick-github')));
    await tester.pumpAndSettle();
    expect(find.text('Official · GitHub'), findsOneWidget);
    expect(find.textContaining('Web service · recommended'), findsOneWidget);
    expect(
      find.textContaining('Node.js (npx) is not installed yet'),
      findsOneWidget,
    );
    final field = find.byKey(const ValueKey('mcp-need-GITHUB_TOKEN'));
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .obscureText,
      isTrue,
    );
    await tester.enterText(field, 'ghp_token');
    await tester.enterText(
      find.byKey(const ValueKey('mcp-catalog-name')),
      'bad name',
    );
    await tester.pump();
    final preview = find.widgetWithText(FilledButton, 'Preview');
    expect(tester.widget<FilledButton>(preview).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('mcp-catalog-name')),
      'gh',
    );
    await tester.pump();
    await tester.tap(preview);
    await tester.pump();
    expect(previews.single['option'], 'h-gh');
    expect(previews.single['values'], {'GITHUB_TOKEN': 'ghp_token'});
  });

  testWidgets('a secret that would be on the command line stops it', (
    tester,
  ) async {
    final (_, previews) = await pump(
      tester,
      search: (params) => {
        'servers': [
          _server('tokens', [
            _option(
              'h-t',
              'npm',
              needs: [_need('token', secret: true)],
              onCommandLine: ['token'],
            ),
          ], name: 'io.github.someone/tokens'),
        ],
        'cursor': '',
        'total': 1,
      },
    );
    await tester.tap(find.text('MCP registry'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mcp-registry-search')),
      'tokens',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'tokens'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Anyone can publish'), findsOneWidget);
    expect(find.text('GitHub account someone'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('mcp-need-token')), 's');
    await tester.pump();
    expect(
      find.text(
        'token would be on the command line, where other users of this PC can read it.',
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Preview'))
          .onPressed,
      isNull,
    );
    // Left empty it is optional, and the server can be added without it.
    await tester.enterText(find.byKey(const ValueKey('mcp-need-token')), '');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Preview'));
    await tester.pump();
    expect(previews.single['option'], 'h-t');
  });

  testWidgets('registry pages go forward and back by cursor', (tester) async {
    final (calls, _) = await pump(
      tester,
      search: (params) {
        final second = params['cursor'] == 'c1';
        return {
          'servers': [
            for (var i = 0; i < (second ? 3 : 20); i++)
              _server('${second ? 'b' : 'a'}$i', [_option('h$i', 'npm')]),
          ],
          'cursor': second ? '' : 'c1',
          'total': null,
        };
      },
    );
    await tester.tap(find.text('MCP registry'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('mcp-registry-search')),
      'git',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      find.text('Servers found: {0}'.replaceAll('{0}', 'more than 20')),
      findsOneWidget,
    );
    await tester.tap(find.text('Next 20 ›'));
    await tester.pumpAndSettle();
    expect(find.text('b0'), findsOneWidget);
    expect(find.text('Servers found: 23'), findsOneWidget);
    await tester.tap(find.text('‹ Previous 20'));
    await tester.pumpAndSettle();
    expect(find.text('a0'), findsOneWidget);
    expect([for (final c in calls.skip(1)) c.$2['cursor']], ['', 'c1', '']);
  });
}
