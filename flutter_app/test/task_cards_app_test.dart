import 'package:asterism/python_transport.dart';
import 'dart:convert';
import 'dart:io';
import 'package:asterism/backend.dart';
import 'package:asterism/agent_map.dart';
import 'package:asterism/settings_view.dart';
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
installed_runtime=False
catalog_loads=0
settings={'map_scan_interval':6,'map_light_fps':20,'flutter_theme_mode':'system','map_layers':['agents']}
addon={'id':'fixture-addon','name':'Fixture adapter','version':'1.0','summary':'Summary',
 'kind':'agent','state':'verified','enabled':False,'supported':True,'verified':True,'provides':['test']}
new_addon={**addon,'id':'catalog-addon','name':'Catalog adapter','version':'2.0','provides':['new']}
runtime={'key':'fixture','name':'Fixture provider','installed':True,'running':True,'tunable':True,
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
 if m=='app.snapshot':r={'agents':[{'command':'test','name':'Test agent','version':'1.0','installed':True}],
  'projects':{'test':{'history':[],'default':'/home/u','pinned':''}},'settings':settings,'language':'en','setup_needed':welcome,'theme':{}}
 elif m=='settings.update':settings.update(p['values']);r=settings
 elif m=='app.theme':r={'theme':{}}
 elif m=='addons.list':r={'addons':[addon]+([new_addon] if installed else [])}
 elif m=='system.cached':r={'nodes':[],'edges':[],'notes':[],'helpers':[]}
 elif m=='map.snapshot':r={'nodes':nodes,'edges':[{'source':'agent:test','target':'mcp:known-server','kind':'mcp'}] if connected else [],'activity':{},'pending':Path('pending').exists()}
 elif m=='system.refresh':tasks['system']={'nodes':[],'edges':[],'notes':[],'helpers':[]};r={'task':'system'}
 elif m=='setup.detect':tasks['detect']={'installed':['fixture-addon']};r={'task':'detect'}
 elif m=='providers.snapshot':r={'local':[runtime],'online':[],'folders':[]}
 elif m=='connections.snapshot':r={'agents':[{'command':'test','name':'Test agent','mcp':True,'skills':False}],
  'providers':[],'skills':[],'mcp':[{'id':'known-server','name':'Known server','target':'example.test','agents':['test'] if connected else []}], 'focus':['agent:test']}
 elif m=='connections.author_preview':r={'plan':'opaque','empty':False,'files':[],'links_add':[],'links_remove':[],'kind':p['kind'],'agents':['Test agent'],'focus':['agent:test']}
 elif m=='connections.preview':r={'plan':'opaque','empty':False,'files':[],'links_add':[],'links_remove':[],
  'command':'test','item':'known-server','remove':False,'focus':['agent:test','mcp:known-server']}
 elif m=='connections.move_preview':r={'plan':'opaque-remove','empty':False,'files':[],'links_add':[],'links_remove':[],'focus':['agent:test','mcp:known-server']}
 elif m=='connections.undo':connected=False;r={'restored':['fixture']}
 elif m=='connections.apply':connected=p['plan']!='opaque-remove';tasks['connect']={'ok':True,'undo':'undo-token'};r={'task':'connect'}
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
 elif m=='guide.snapshot':
  guides=sum(1 for l in open('requests.jsonl') if '"guide.snapshot"' in l)
  steps=[{'title':'llama.cpp','done':installed_runtime,'detail':'','action':'providers' if installed_runtime else 'install-runtime','target':'llamacpp'},
         {'title':'Connections','done':False,'detail':'','action':'providers'}]
  tasks['guide']={'routes':[{'id':'local','kind':'local','title':'Local route','access':'On this PC','command':'test','name':'Test agent','verified':False,'steps':steps}],'selected':'local','loads':guides}
  r={'task':'guide'}
 elif m=='installers.preview':
  tasks['ipreview']={'installer':'inst-1','kind':p['kind'],'key':p['key'],'name':'llama.cpp','version':'b9000-'+p.get('build','vulkan'),'size':10,
   'files':[{'name':'llama.tar.gz','size':10}],'folder':'/home/u/.local/share/ai-agents-map/llamacpp','models':'/home/u/.local/share/ai-agents-map/llamacpp/models',
   'gpu':{'vendor':'amd','name':'AMD · card1'},'build':p.get('build','vulkan'),'builds':[['vulkan','Vulkan'],['cpu','CPU']],'has_service':True}
  r={'task':'ipreview'}
 elif m=='installers.install':installed_runtime=True;tasks['iinstall']={'ok':True,'kind':'runtime','key':'llamacpp','version':'b9000'};r={'task':'iinstall'}
 elif m=='agents.details':r={'model':'','plan':'','providers':[],'limits':[],'today_prompts':0,'today_sessions':0,'today_tokens':0,'actions':{}}
 elif m=='agents.security':r={'agent':'test','name':'Test agent','known':True,'level':'high','rules':[],'files':[],'note':'',
  'settings':[{'key':'ask','title':'Asks first','explain':'','editable':True,'current':'never','default':'always','recommended':'always',
   'choices':[{'value':'always','label':'Always','explain':'','risk':1},{'value':'never','label':'Never','explain':'','risk':3}]}],
  'risks':[{'level':'high','title':'It never asks','why':'','lower':'','fix_key':'ask','fix_value':'always'}]}
 elif m=='agents.security_preview':r={'plan':'opaque-security','empty':False,'files':[],'links_add':[],'links_remove':[],'focus':['agent:test']}
 elif m=='mcp.catalog':
  tasks['mcpcat']={'groups':[{'key':'think','label':'Thinking and memory'}],'picks':[{'key':'time','title':'Time','group':'think','maker':'MCP project',
   'trust':'Reference server · MCP project','trust_hint':'','about':'The current time.','tries':[],'needs':'Nothing.','repository':'https://github.com/x/time','key_url':'',
   'server':{'name':'time','short':'time','title':'Time','description':'','version':'1.0','repository':'','website':'','updated':'','status':'',
    'publisher':{'kind':'','who':''},'options':[{'option':'opt-time','kind':'pypi','label':'pypi · mcp-server-time 1.0','runnable':True,'command':'uvx',
     'args':['mcp-server-time==1.0'],'env':[],'url':'','headers':[],'needs':[],'on_command_line':[]}]}}]}
  r={'task':'mcpcat'}
 elif m=='models.tuning':tasks['tune']={'runtime':'Fixture provider','key':'fixture','gpu':'GPU','vram':8<<30,'stacks':[],'build':'','builds':[],'devices':'','settings':{'*':{}},'tuning':{'mode':['a|b','A mode']},'per_model':False,'models':[],'loaded':[],'vram_used':0,'helpers':[{'command':'test','name':'Test agent'}]};r={'task':'tune'}
 elif m=='models.tuning_ask':tasks['ask']={'summary':'One thing.','agent':p['command'],'suggestions':[{'kind':'setting','title':'Use b','why':'Faster.','model':'*','key':'mode','value':'b'}]};r={'task':'ask'}
 elif m=='models.tuning_preview':r={'plan':'opaque-tune','empty':False,'files':[{'path':'~/.config/x.ini','added':1,'removed':0}],'links_add':[],'links_remove':[],'item':'Fixture provider','notes':[],'focus':['runtime:fixture']}
 elif m=='skills.web_search':tasks['sks']={'skills':[{'name':'pdf','skill_id':'pdf','repo':'a/skills','installs':3}]};r={'task':'sks'}
 elif m=='skills.web_fetch':tasks['skf']={'fetched':'f1','name':'pdf','repo':'a/skills','skill_id':'pdf','description':'Reads PDFs.','files':['SKILL.md'],'scripts':[],'targets':['~/.agents/skills'],'agents':[{'command':'test','name':'Test agent'}]};r={'task':'skf'}
 elif m=='skills.web_preview':r={'plan':'opaque-skill','empty':False,'files':[],'new_files':['~/.agents/skills/pdf/SKILL.md'],'links_add':[],'links_remove':[],'kind':'skills','agents':[],'focus':['agent:test']}
 elif m=='mcp.tools_cached':r={'cached':None}
 elif m=='mcp.tools':tasks['tools']={'status':'ok','checked':'2026-10-29T12:00:00','server':'known 1','tools':[{'name':'lookup','description':'Looks up'}],'prompts':[]};r={'task':'tools'}
 elif m=='mcp.option_preview':r={'plan':'opaque-catalog','empty':False,'files':[],'links_add':[],'links_remove':[],'kind':'mcp','agents':['Test agent'],'focus':['agent:test']}
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
  final backend = await tester.runAsync(
    () => PythonTransport.start(dir.path).then(Backend.fromTransport),
  );
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
  testWidgets(
    'map drag opens review, Cancel has no apply, Apply and Undo restore connection',
    (tester) async {
      final dir = await mountApp(tester);
      Future<void> draw() async {
        final from = tester.getCenter(find.text('Test agent'));
        final to = tester.getCenter(find.text('Known server'));
        await tester.dragFrom(from, to - from);
        await settleService(tester);
      }

      await draw();
      expect(find.byType(ConnectionReview), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'connections.apply'),
        isEmpty,
      );
      await draw();
      await tester.tap(find.text('Apply'));
      await settleService(tester);
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'connections.undo').length,
        1,
      );
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );
  testWidgets(
    'hook to empty opens removal review; Cancel leaves the connection',
    (tester) async {
      final dir = await mountApp(tester);
      final from = tester.getCenter(find.text('Test agent')),
          to = tester.getCenter(find.text('Known server'));
      await tester.dragFrom(from, to - from);
      await settleService(tester);
      await tester.tap(find.text('Apply'));
      await settleService(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await settleService(tester);
      await tester.tap(find.text('Test agent'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byTooltip(
          'Move this connection to another compatible box, or to empty space to disconnect.',
        ),
        const Offset(0, 240),
      );
      await settleService(tester);
      expect(find.byType(ConnectionReview), findsOneWidget);
      final move = requests(
        dir,
      ).singleWhere((q) => q['method'] == 'connections.move_preview');
      expect(move['params'], {
        'agent': 'agent:test',
        'old': 'mcp:known-server',
        'new': null,
      });
      await tester.tap(find.text('Cancel'));
      await settleService(tester);
      expect(
        requests(dir).where((q) => q['method'] == 'connections.apply').length,
        1,
      );
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );
  for (final pending in [false, true]) {
    testWidgets(
      'live scans retain equal snapshots and map widgets (pending=$pending)',
      (tester) async {
        final dir = await mountApp(tester);
        if (pending) File('${dir.path}/pending').writeAsStringSync('pending');
        final before = requests(
          dir,
        ).where((q) => q['method'] == 'map.snapshot').length;
        final original = tester.widget<AgentMap>(
          find.byKey(const ValueKey('ai-map')),
        );
        await tester.pump(const Duration(seconds: 8));
        await settleService(tester);
        final current = tester.widget<AgentMap>(
          find.byKey(const ValueKey('ai-map')),
        );
        if (!pending) expect(identical(original, current), true);
        expect(
          requests(dir).where((q) => q['method'] == 'map.snapshot').length,
          greaterThan(before),
        );
        if (pending) {
          expect(current.graph['pending'], true);
          final polls = requests(
            dir,
          ).where((q) => q['method'] == 'map.snapshot').length;
          await tester.pump(const Duration(seconds: 4));
          await settleService(tester);
          expect(
            requests(dir).where((q) => q['method'] == 'map.snapshot').length,
            greaterThan(polls),
          );
          expect(
            identical(
              tester.widget<AgentMap>(find.byKey(const ValueKey('ai-map'))),
              current,
            ),
            true,
          );
        }
        expect(tester.takeException(), isNull);
        await unmountApp(tester);
      },
    );
  }
  testWidgets('theme and frame-rate settings apply through the service', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Settings'));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('theme-dark')));
    await settleService(tester);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(
      Theme.of(tester.element(find.byType(SettingsView))).brightness,
      Brightness.dark,
    );
    final rate = find.byKey(const ValueKey('map-light-fps-20'));
    await tester.ensureVisible(rate);
    await tester.pumpAndSettle();
    await tester.tap(rate);
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 fps').last);
    await settleService(tester);
    expect(
      requests(dir)
          .where((q) => q['method'] == 'settings.update')
          .any((q) => q['params']['values']['map_light_fps'] == 60),
      isTrue,
    );
    tester.widget<SettingsView>(find.byType(SettingsView)).onBack();
    await settleService(tester);
    expect(
      tester.widget<AgentMap>(find.byKey(const ValueKey('ai-map'))).lightFps,
      60,
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a tuning setting goes through the preview', (tester) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Providers and models'));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('performance-fixture')));
    await settleService(tester);
    expect(find.text('A mode'), findsOneWidget);
    await tester.tap(find.text('—'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b').last);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'models.tuning_preview')['params'],
      {'key': 'fixture', 'section': '*', 'setting': 'mode', 'value': 'b'},
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-tune'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('tips from an agent are asked and one is applied', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Providers and models'));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('performance-fixture')));
    await settleService(tester);
    final ask = find.byKey(const ValueKey('tuning-ask'));
    await tester.ensureVisible(ask);
    await tester.pumpAndSettle();
    await tester.tap(ask);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'models.tuning_ask')['params'],
      {'key': 'fixture', 'command': 'test'},
    );
    expect(find.text('One thing.'), findsOneWidget);
    final apply = find.widgetWithText(TextButton, 'Apply');
    await tester.ensureVisible(apply);
    await tester.pumpAndSettle();
    await tester.tap(apply);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'models.tuning_preview')['params'],
      {'key': 'fixture', 'section': '*', 'setting': 'mode', 'value': 'b'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a skill from the web goes through the preview', (tester) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Connections'));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('skills-web-open')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('skills-web-search')),
      'pdf',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('skill-a/skills/pdf')));
    await settleService(tester);
    final preview = find.widgetWithText(FilledButton, 'Preview');
    await tester.ensureVisible(preview);
    await tester.pumpAndSettle();
    await tester.tap(preview);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'skills.web_preview')['params'],
      {'fetched': 'f1', 'folder': '~/.agents/skills', 'agents': []},
    );
    expect(find.text('~/.agents/skills/pdf/SKILL.md'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-skill'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a set-up MCP server is asked for its tools', (tester) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Connections'));
    await settleService(tester);
    final card = find.text('Known server');
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await settleService(tester);
    expect(find.textContaining('Not asked yet.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-ask-known-server')));
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'mcp.tools')['params'],
      {'name': 'known-server'},
    );
    expect(find.text('lookup'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a recommended MCP server goes through the preview', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await tester.tap(find.byTooltip('Connections'));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('mcp-catalog-open')));
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('mcp-pick-time')));
    await tester.pumpAndSettle();
    final preview = find.widgetWithText(FilledButton, 'Preview');
    await tester.ensureVisible(preview);
    await tester.pumpAndSettle();
    await tester.tap(preview);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'mcp.option_preview')['params'],
      {
        'option': 'opt-time',
        'name': 'time',
        'values': {},
        'agents': ['test'],
      },
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-catalog'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a security setting is lowered through the preview', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    tester
        .widget<AgentMap>(find.byKey(const ValueKey('ai-map')))
        .onAgent('test');
    await settleService(tester);
    await tester.tap(find.text('Security settings'));
    await settleService(tester);
    expect(find.text('High risk'), findsOneWidget);
    await tester.ensureVisible(find.text('Lower it…'));
    await tester.tap(find.text('Lower it…'));
    await settleService(tester);
    final preview = requests(
      dir,
    ).lastWhere((q) => q['method'] == 'agents.security_preview');
    expect(preview['params'], {
      'command': 'test',
      'key': 'ask',
      'value': 'always',
    });
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-security'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('steps taken from the guide return to it, refreshed', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    int guides() =>
        requests(dir).where((q) => q['method'] == 'guide.snapshot').length;
    await tester.tap(find.byTooltip('Your first agent'));
    await settleService(tester);
    expect(guides(), 1);
    // Install the route's local LLM: reviewed, installed, the guide again.
    await tester.tap(find.text('Install llama.cpp…'));
    await settleService(tester);
    expect(find.textContaining('b9000-vulkan'), findsWidgets);
    await tester.ensureVisible(find.text('Start at login'));
    await tester.tap(find.text('Start at login'));
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Install'));
    await tester.tap(find.widgetWithText(FilledButton, 'Install'));
    await settleService(tester);
    final install = requests(
      dir,
    ).lastWhere((q) => q['method'] == 'installers.install');
    expect(install['params'], {
      'installer': 'inst-1',
      'start_now': false,
      'start_at_login': true,
    });
    expect(guides(), 2);
    // Providers from the guide: Back comes back to the guide, refreshed.
    await tester.tap(find.text('Providers and models').first);
    await settleService(tester);
    await tester.tap(find.text('Back').first);
    await settleService(tester);
    expect(guides(), 3);
    expect(find.text('Local route'), findsWidgets);
    // Chosen from the menu, Providers goes back to the map, not the guide.
    await tester.tap(find.byTooltip('Providers and models'));
    await settleService(tester);
    await tester.tap(find.text('Back').first);
    await settleService(tester);
    expect(guides(), 3);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });
}
