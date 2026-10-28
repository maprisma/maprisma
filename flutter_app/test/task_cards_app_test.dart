import 'dart:convert';
import 'dart:io';
import 'package:asterism/backend.dart';
import 'package:asterism/main.dart';
import 'package:asterism/connections_view.dart';
import 'package:asterism/task_card.dart';
import 'package:asterism/map_addons_focus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const service = r'''
import json,sys
from pathlib import Path
connected=False
welcome=False
install_fails=False
installed=False
catalog_loads=0
addon={'id':'fixture-addon','name':'Fixture adapter','version':'1.0','summary':'Summary',
 'kind':'agent','state':'verified','enabled':False,'supported':True,'verified':True,'provides':['test']}
new_addon={**addon,'id':'catalog-addon','name':'Catalog adapter','version':'2.0','provides':['new']}
runtime={'key':'fixture','name':'Fixture provider','installed':True,'running':True,
 'address':'','models_dir':'','models':['example-model'],'can_load':True,
 'can_control':False,'can_import':False,'download':'file','focus':['runtime:fixture']}
nodes=[{'id':ident,'kind':kind,'column':column,'label':label,'detail':''}
 for ident,kind,column,label in [('agent:test','agent',1,'Test agent'),
 ('runtime:fixture','runtime',2,'Fixture provider'),('model:runtime:fixture:example-model','model',3,'example-model'),
 ('mcp:known-server','mcp',0,'Known server')]]
tasks={}
for line in sys.stdin:
 q=json.loads(line);m=q['method'];p=q.get('params',{})
 with open('requests.jsonl','a') as log:log.write(json.dumps(q)+'\n')
 if m=='app.snapshot':r={'agents':[],'projects':{},'settings':{'map_scan_interval':6},'language':'en','setup_needed':welcome,'theme':{}}
 elif m=='app.theme':r={'theme':{}}
 elif m=='addons.list':r={'addons':[addon]+([new_addon] if installed else [])}
 elif m=='system.cached':r={'nodes':[],'edges':[],'notes':[],'helpers':[]}
 elif m=='map.snapshot':r={'nodes':nodes,'edges':[{'source':'agent:test','target':'mcp:known-server','kind':'mcp'}] if connected else [],'activity':{}}
 elif m=='system.refresh':tasks['system']={'nodes':[],'edges':[],'notes':[],'helpers':[]};r={'task':'system'}
 elif m=='setup.detect':tasks['detect']={'installed':['fixture-addon']};r={'task':'detect'}
 elif m=='providers.snapshot':r={'local':[runtime],'online':[],'folders':[]}
 elif m=='connections.snapshot':r={'agents':[{'command':'test','name':'Test agent','mcp':True,'skills':False}],
  'providers':[],'skills':[],'mcp':[{'id':'known-server','name':'Known server','target':'example.test','agents':['test'] if connected else []}], 'focus':['agent:test']}
 elif m=='connections.author_preview':r={'plan':'opaque','empty':False,'files':[],'links_add':[],'links_remove':[],'kind':p['kind'],'agents':['Test agent'],'focus':['agent:test']}
 elif m=='connections.preview':r={'plan':'opaque','empty':False,'files':[],'links_add':[],'links_remove':[],
  'command':'test','item':'known-server','remove':False,'focus':['agent:test','mcp:known-server']}
 elif m=='connections.apply':connected=True;tasks['connect']={'ok':True,'undo':'undo-token'};r={'task':'connect'}
 elif m=='providers.run':
  op=p['operation'];tasks[op]=({'repos':[{'id':'owner/repo'}]} if op=='models.search' else
   {'files':[{'name':'model.gguf','quant':'Q4','size':123}]} if op=='models.files' else {'ok':True})
  r={'task':op,'focus':['runtime:fixture']}
 elif m=='addons.catalog':
  catalog_loads+=1
  entry={'id':'catalog-addon','name':'Catalog adapter','version':'2.0','kind':'agent',
   'supported':True,'action':'' if installed else 'install','installed_version':'2.0' if installed else '',
   'preview':'catalog-'+str(catalog_loads),'reads':[],'sends':[],'capabilities':[],'privacy':1}
  tasks['catalog']={'entries':[entry]};r={'task':'catalog'}
 elif m=='addons.install':
  installed=not install_fails
  tasks['install']={'ok':True};r={'task':'install'}
 elif m=='tasks.status':r=({'state':'failed'} if p['task']=='install' and install_fails else {'state':'done','result':tasks[p['task']]})
 else:r={}
 print(json.dumps({'id':q['id'],'result':r}),flush=True)
''';

Future<void> settleService(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> unmountApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump(const Duration(seconds: 36));
}

Future<Directory> mountApp(
  WidgetTester tester, {
  bool welcome = false,
  bool installFails = false,
  double? areaWidth,
}) async {
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('asterism-review-cards-');
  File('${dir.path}/flutter_backend.py').writeAsStringSync(
    service
        .replaceFirst('welcome=False', 'welcome=${welcome ? 'True' : 'False'}')
        .replaceFirst(
          'install_fails=False',
          'install_fails=${installFails ? 'True' : 'False'}',
        ),
  );
  final backend = await tester.runAsync(() => Backend.start(dir.path));
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => dir.deleteSync(recursive: true));
  final app = AsterismApp(
    key: UniqueKey(),
    connectBackend: () async => backend!,
  );
  await tester.pumpWidget(
    areaWidth == null
        ? app
        : Align(
            child: SizedBox(width: areaWidth, child: app),
          ),
  );
  await settleService(tester);
  return dir;
}

List<Map<String, dynamic>> requests(Directory dir) => File(
  '${dir.path}/requests.jsonl',
).readAsLinesSync().map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
int forcedScans(Directory dir) => requests(dir)
    .where((q) => q['method'] == 'map.snapshot' && q['params']['force'] == true)
    .length;
int snapshots(Directory dir) =>
    requests(dir).where((q) => q['method'] == 'app.snapshot').length;

void main() {
  testWidgets(
    'search/files do no inventory refresh; model load scans once; idle surfaces keep updates',
    (tester) async {
      final dir = await mountApp(tester);
      final baseline = forcedScans(dir);
      await tester.tap(find.byTooltip('Providers and models'));
      await settleService(tester);
      expect(forcedScans(dir), baseline);
      expect(find.text('Providers and models'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
      await tester.tap(find.text('Models (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Load'));
      await settleService(tester);
      expect(forcedScans(dir), baseline + 1);
      expect(find.text('Succeeded'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNotNull,
      );
      final liveBefore = requests(
        dir,
      ).where((q) => q['method'] == 'map.snapshot').length;
      await tester.pump(const Duration(seconds: 8));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'map.snapshot').length,
        greaterThan(liveBefore),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Download model'));
      await tester.pumpAndSettle();
      final beforeSearch = snapshots(dir);
      final beforeSearchScans = forcedScans(dir);
      await tester.enterText(find.byType(TextField), 'chat');
      await tester.tap(find.byTooltip('Search'));
      await settleService(tester);
      expect(find.text('owner/repo'), findsOneWidget);
      await tester.tap(find.text('owner/repo'));
      await settleService(tester);
      expect(find.text('model.gguf'), findsOneWidget);
      expect(snapshots(dir), beforeSearch);
      expect(forcedScans(dir), beforeSearchScans);
      final browserLive = requests(
        dir,
      ).where((q) => q['method'] == 'map.snapshot').length;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 7)),
      );
      await tester.pump(const Duration(seconds: 8));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'map.snapshot').length,
        greaterThan(browserLive),
      );
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'connection search survives review and apply; first result includes Undo',
    (tester) async {
      final dir = await mountApp(tester);
      await tester.tap(find.byTooltip('Connections'));
      await settleService(tester);
      final field = find.byType(TextField);
      await tester.enterText(field, 'Known');
      await tester.tap(find.text('Known server'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Test agent'));
      await settleService(tester);
      expect(find.byType(ConnectionsView), findsNothing);
      expect(find.byType(ConnectionsView, skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleService(tester);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Known',
      );
      final scans = forcedScans(dir);
      await tester.tap(find.widgetWithText(SwitchListTile, 'Test agent'));
      await settleService(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await settleService(tester);
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Undo'), findsOneWidget);
      expect(forcedScans(dir), scans + 1);
      final host = tester.widget<TaskHost>(find.byType(TaskHost).last);
      expect((host.graph['edges'] as List), isNotEmpty);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'Known',
      );
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );
  testWidgets(
    'welcome exclusions survive catalog progress and a cancelled review',
    (tester) async {
      final dir = await mountApp(tester, welcome: true);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      final catalog = find.widgetWithText(
        TextButton,
        'Look for add-ons online',
      );
      await tester.ensureVisible(catalog);
      await tester.tap(catalog);
      await settleService(tester);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(
        requests(dir).where((q) => q['method'] == 'addons.catalog').length,
        1,
      );
      await tester.ensureVisible(find.text('Catalog adapter · 2.0'));
      await tester.tap(find.text('Catalog adapter · 2.0'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Get add-on'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get add-on'));
      await settleService(tester);
      expect(find.byType(MapAddonsFocus), findsNothing);
      await tester.tap(find.text('Cancel'));
      await settleService(tester);
      final focus = tester.widget<MapAddonsFocus>(find.byType(MapAddonsFocus));
      expect(focus.welcome, isTrue);
      final checkbox = find.byType(Checkbox);
      await tester.ensureVisible(checkbox);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  for (final fails in [false, true]) {
    testWidgets(
      'catalog reload after install (failure=$fails) retains result and updated entries',
      (tester) async {
        final dir = await mountApp(tester, welcome: true, installFails: fails);
        final scans = forcedScans(dir);
        final catalog = find.widgetWithText(
          TextButton,
          'Look for add-ons online',
        );
        await tester.ensureVisible(catalog);
        await tester.tap(catalog);
        await settleService(tester);
        await tester.ensureVisible(find.text('Catalog adapter · 2.0'));
        await tester.tap(find.text('Catalog adapter · 2.0'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Get add-on'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Get add-on'));
        await settleService(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Install'));
        await settleService(tester);
        expect(
          find.text(fails ? 'The action could not be completed.' : 'Succeeded'),
          findsOneWidget,
        );
        expect(
          requests(dir).where((q) => q['method'] == 'addons.catalog').length,
          2,
        );
        expect(forcedScans(dir), scans);
        final focus = tester.widget<MapAddonsFocus>(
          find.byType(MapAddonsFocus, skipOffstage: false),
        );
        expect(focus.entries!.single['preview'], 'catalog-2');
        expect(focus.entries!.single['action'], fails ? 'install' : '');
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
        expect(
          find.text('The catalog loads only when you ask to look online.'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await unmountApp(tester);
      },
    );
  }
  testWidgets(
    'a narrow map area in a wider window does not trigger a completion scan',
    (tester) async {
      final dir = await mountApp(tester, areaWidth: 880);
      final scans = forcedScans(dir);
      await tester.tap(find.byTooltip('Providers and models'));
      await settleService(tester);
      await tester.tap(find.text('Models (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Load'));
      await settleService(tester);
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.byKey(const ValueKey('full-task')), findsOneWidget);
      expect(forcedScans(dir), scans);
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'new MCP form requests a private preview and Cancel performs no apply',
    (tester) async {
      final dir = await mountApp(tester);
      await tester.tap(find.byTooltip('Connections'));
      await settleService(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add MCP server'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mcp-name')),
        'new-server',
      );
      await tester.enterText(
        find.byKey(const ValueKey('mcp-command')),
        '/test/program',
      );
      final recipient = find.widgetWithText(CheckboxListTile, 'Test agent');
      await tester.ensureVisible(recipient);
      await tester.pumpAndSettle();
      await tester.tap(recipient);
      final preview = find.widgetWithText(FilledButton, 'Preview');
      await tester.ensureVisible(preview);
      await tester.pumpAndSettle();
      await tester.tap(preview);
      await settleService(tester);
      final calls = requests(dir);
      expect(
        calls.singleWhere(
          (q) => q['method'] == 'connections.author_preview',
        )['params']['name'],
        'new-server',
      );
      expect(find.text('Agents: Test agent'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'connections.apply'),
        isEmpty,
      );
      final name = find.byKey(const ValueKey('mcp-name'));
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      expect(tester.widget<TextFormField>(name).controller!.text, 'new-server');
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );
}
