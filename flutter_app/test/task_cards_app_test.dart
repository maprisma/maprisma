import 'dart:async';
import 'support/python_transport.dart';
import 'dart:convert';
import 'dart:io';
import 'package:maprisma/backend.dart';
import 'package:maprisma/first_agent_view.dart';
import 'package:maprisma/action_rules_window.dart';
import 'package:maprisma/overlay_window.dart';
import 'package:maprisma/agent_map.dart';
import 'package:maprisma/settings_view.dart';
import 'package:maprisma/main.dart';
import 'package:maprisma/connections_view.dart';
import 'package:maprisma/test_shots.dart';
import 'package:maprisma/map_addons_focus.dart';
import 'package:maprisma/map_smart_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart' show TerminalView;

import 'support/a11y.dart';

const service = r'''
import json,sys,threading,time
from pathlib import Path
out=threading.Lock()
connected=False
welcome=False
install_fails=False
interrupted=False
installed=False
installed_runtime=False
catalog_loads=0
settings={'map_scan_interval':6,'map_light_fps':20,'flutter_theme_mode':'system','map_layers':['agents','online','local','models','mcp','skills'],'system_map_columns':['pc','disks','programs','tools','folders'],'language':'en'}
if Path('window_popup').exists():settings['window_mode']='popup'
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
 elif m=='settings.get':
  # Another process may have changed them: other.json is merged in.
  if Path('other.json').exists():settings.update(json.loads(Path('other.json').read_text()));Path('other.json').unlink()
  r=settings
 elif m=='desktop.snapshot':r={'name':'omarchy' if Path('omarchy').exists() else 'generic','theme_dir':''}
 elif m=='window.popup':r={'placed':True,'x':10,'y':40,'width':p['width'],'height':p['height']}
 elif m=='agents.usage_refresh':tasks['usage']={'ok':True};r={'task':'usage'}
 elif m=='app.theme':r={'theme':json.loads(Path('theme.json').read_text()) if Path('theme.json').exists() else {}}
 elif m=='addons.list':r={'addons':[addon]+([new_addon] if installed else [])}
 elif m=='system.cached':r={'nodes':[],'edges':[],'notes':[],'helpers':[]}
 elif m=='map.snapshot':r={'nodes':[({**n,'status':'running'} if n['id']=='agent:test' and Path('agent_running').exists() else n) for n in nodes],'edges':[{'source':'agent:test','target':'mcp:known-server','kind':'mcp'}] if connected else [],'activity':{},'pending':Path('pending').exists()}
 elif m=='agents.traffic':r={'available':True,'agents':{}}
 elif m=='agents.halt_preview':r={'instances':[{'label':'PID 42','preview':'halt-42'}]}
 elif m=='system.refresh':
  tasks['system']={'nodes':[{'id':'found:/data/models','kind':'models','label':'Models','path':'/data/models','found':'a','status':'found','provider':''}] if Path('found_on_pc').exists() else [],'edges':[],'notes':[],'helpers':[],'search_done':Path('found_on_pc').exists()};r={'task':'system'}
 elif m=='sessions.start':r={'session':'s'+str(len(tasks)),'path':'/home/u'};tasks['s'+str(len(tasks))]={}
 elif m=='sessions.read':r={'text':'','ended':False}
 elif m=='sessions.write':r={'accepted':len(__import__('base64').b64decode(p['data'])),'ended':False}
 elif m=='existing.preview':r={'plan':'opaque-existing','files':[],'notes':[],'empty':False}
 elif m=='existing.apply':tasks['existing']={'ok':True};r={'task':'existing'}
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
   'files':[{'name':'llama.tar.gz','size':10}],'folder':'/home/u/.local/share/maprisma/llamacpp','models':'/home/u/.local/share/maprisma/llamacpp/models',
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
 elif m=='models.slots_preview' and Path('no-slots').exists():r={'empty':True}
 elif m=='models.slots_preview':r={'plan':'opaque-slots','empty':False,'files':[{'path':'~/.config/llama.cpp/server.env','added':1,'removed':0}],'links_add':[],'links_remove':[],'notes':['Fixture provider keeps 2 models loaded at once'],'warnings':['Too big together.'],'reload':True,'focus':['runtime:fixture']}
 elif m=='models.slots_reload':r={'ok':True}
 elif m=='updates.check':tasks['up']={'updates':[{'kind':'agent','column':'agents','key':'test','name':'Test agent','current':'1.0','available':'1.1','command':['mise','upgrade','test'],'page':False}]};r={'task':'up'}
 elif m=='updates.run':r=({'started':True} if p.get('running_ok') else {'started':False,'running':1,'here':0})
 elif m=='checks.mcp_check':tasks['mcpc']={'on':True,'summary':'1 update','servers':2,'agent':'Test agent','task_agent':'Test agent','due':False,'updates':[{'name':'fetch','column':'mcp','app':'@acme/fetch-mcp','current':'1.4.2','latest':'1.5.0','url':'https://www.npmjs.com/package/@acme/fetch-mcp','notes':'Faster.','source':'npm','program':'','on_pc':False,'text':'MCP server fetch 1.5.0 is available (you have 1.4.2)'}]};r={'task':'mcpc'}
 elif m=='checks.mcp_release':r={'opened':True}
 elif m=='changes.undo' and Path('slow').exists():
  # Answered only once 'release' exists: the app stays busy meanwhile.
  def later(i=q['id']):
   while not Path('release').exists():time.sleep(0.05)
   with out:print(json.dumps({'id':i,'result':{'ok':True,'restored':[]}}),flush=True)
  threading.Thread(target=later,daemon=True).start();continue
 elif m=='changes.history':r={'changes':[{'id':'20261030-100000-000000','when':'2026-10-30T10:00:00.000','changed':['~/.claude.json'],'count':1,'undoable':['~/.claude.json']},{'id':'20261029-090000-000000','when':'2026-10-29T09:00:00.000','changed':['~/.codex/config.toml'],'count':1,'undoable':[]}]}
 elif m=='changes.undo':r={'ok':True,'restored':['~/.claude.json']}
 elif m=='checks.mcp_task':r={'preview':'mcp-prev','name':'Test agent','prompt':'The MCP server "fetch" runs the npm package @acme/fetch-mcp pinned to 1.4.2.','topic':'mcp-update'}
 elif m=='gpu.snapshot':tasks['gpu']={'vram_used':0,'vram_total':0,'busy':None,'runtimes':{},'badges':{}};r={'task':'gpu'}
 elif m=='map.badges':r={'badges':{},'rate_due':False}
 elif m in ('agents.projects','agents.costs'):r={'card':None}
 elif m=='found.scan':tasks['found']={'mcp':[],'versions':[],'not_looked':[],'skills':[]};r={'task':'found'}
 elif m=='found.hints':r={'lines':[{'kind':'found','column':'mcp','text':'New on this PC: wordcraft','mcp':True,'skills':False}]}
 elif m=='found.list':r=({'checked':True,'set_up':1,'not_looked':[],'items':[{'name':'wordcraft','where':'~/.local/bin/wordcraft-cli','command':['/h/.local/bin/wordcraft-cli','mcp','--headless'],'sure':True,'version':'','new':True,'ready':True},{'name':'vectorcraft','where':'vectorcraft.AppImage','command':['/h/Applications/vectorcraft-1.2.0/usr/bin/vectorcraft-cli','mcp'],'sure':True,'version':'1.2.0','new':False,'ready':False,'program':'/h/Applications/vectorcraft-1.2.0/usr/bin/vectorcraft-cli','unpack_text':'Unpacks vectorcraft.AppImage into ~/Applications/vectorcraft-1.2.0 first (the server lives inside it).'}],'updates':[{'name':'gridcraft','from':'0.7.0','to':'0.8.0','program':'/h/Applications/gridcraft-0.8.0/usr/bin/gridcraft-cli','ready':True,'used_by':'Update · used by Claude Code'}],'not_looked_text':'1 AppImage not looked into yet (wordcraft.AppImage).','looking_text':'Looking inside 1 AppImages…'} if p['kind']=='mcp' else {'checked':True,'items':[]})
 elif m=='found.seen':r={'ok':True}
 elif m=='found.update_preview':r={'plan':'opaque-update','empty':False,'files':[{'path':'~/.claude.json','added':1,'removed':1}],'links_add':[['~/.local/bin/gridcraft','/h/Applications/gridcraft-0.8.0/usr/bin/gridcraft-cli']],'links_remove':[['~/.local/bin/gridcraft','/h/Applications/gridcraft-0.7.0/usr/bin/gridcraft-cli']],'retire':['~/Applications/gridcraft-0.7.0'],'notes':['The old version is kept with the backup for 7 days: Undo brings everything back.'],'kind':'mcp','focus':['mcp:gridcraft']}
 elif m in ('found.look_inside','found.unpack'):tasks[m]={'ok':True};r={'task':m}
 elif m=='addons.hints':r={'lines':[{'kind':'new','text':'Goose is on this PC but not on the map','ids':['agent-goose'],'column':'agents'},{'kind':'updates','column':'agents','text':'Add-on updates ready: Catalog adapter','updates':[{'id':'catalog-addon','name':'Catalog adapter','version':'2.1','current':'2.0','preview':'catalog-1'}]}]}
 elif m=='health.report':tasks['hr']=(json.loads(Path('health.json').read_text()) if Path('health.json').exists() else {'warn':1,'hint':0,'level':'warn','summary':'1 thing to fix','open_text':'1 open problem','areas':[{'key':'agents','title':'Agents','icon':'','findings':[{'level':'warn','column':'agents','title':'Test agent: Not signed in','text':'','action':['details','test']}]}],'uses':[{'key':'coding','title':'Vibe coding','icon':'','blurb':'Describe what you want.','have':['Test agent'],'steps':[{'level':'hint','column':'mcp','title':'Add skills','text':'Ready-made workflows.','action':['addskills']}],'level':'almost'}]});r={'task':'hr'}
 elif m=='agents.health':r={'state':'warn','summary':'Works, one thing to look at: No model chosen','checks':[{'state':'warn','title':'No model chosen','detail':'','step':'Select it on the map.','command':'','sign_in':''}]}
 elif m=='help.snapshot':r={'manual':True}
 elif m=='help.open_manual':r={'opened':True}
 elif m=='jobs.list':r={'jobs':[{'id':'aaaaaaaaaaaa','kind':'model','title':'m.gguf · Fixture provider','state':'interrupted','fraction':0.4}] if interrupted else []}
 elif m=='jobs.discard':interrupted=False;r={'ok':True}
 elif m=='jobs.continue':interrupted=False;tasks['cont']={'ok':True};r={'task':'cont','focus':['runtime:fixture']}
 elif m=='skills.web_search':tasks['sks']={'skills':[{'name':'pdf','skill_id':'pdf','repo':'a/skills','installs':3}]};r={'task':'sks'}
 elif m=='skills.web_fetch':tasks['skf']={'fetched':'f1','name':'pdf','repo':'a/skills','skill_id':'pdf','description':'Reads PDFs.','files':['SKILL.md'],'scripts':[],'targets':['~/.agents/skills'],'agents':[{'command':'test','name':'Test agent'}]};r={'task':'skf'}
 elif m=='skills.web_preview':r={'plan':'opaque-skill','empty':False,'files':[],'new_files':['~/.agents/skills/pdf/SKILL.md'],'links_add':[],'links_remove':[],'kind':'skills','agents':[],'focus':['agent:test']}
 elif m=='mcp.tools_cached':r={'cached':None}
 elif m=='mcp.tools':tasks['tools']={'status':'ok','checked':'2026-10-29T12:00:00','server':'known 1','tools':[{'name':'lookup','description':'Looks up'}],'prompts':[]};r={'task':'tools'}
 elif m=='mcp.option_preview':r={'plan':'opaque-catalog','empty':False,'files':[],'links_add':[],'links_remove':[],'kind':'mcp','agents':['Test agent'],'focus':['agent:test']}
 elif m=='tasks.status':r=({'state':'failed'} if p['task']=='install' and install_fails else {'state':'done','result':tasks[p['task']]})
 else:r={}
 with out:print(json.dumps({'id':q['id'],'result':r}),flush=True)
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
  bool interrupted = false,
  double? areaWidth,
  void Function(Directory dir)? beforeStart,
}) async {
  rootBundle.clear();
  final dir = Directory.systemTemp.createTempSync('maprisma-review-cards-');
  beforeStart?.call(dir);
  File('${dir.path}/flutter_backend.py').writeAsStringSync(
    service
        .replaceFirst('welcome=False', 'welcome=${welcome ? 'True' : 'False'}')
        .replaceFirst(
          'install_fails=False',
          'install_fails=${installFails ? 'True' : 'False'}',
        )
        .replaceFirst(
          'interrupted=False',
          'interrupted=${interrupted ? 'True' : 'False'}',
        ),
  );
  final backend = await tester.runAsync(
    () => PythonTransport.start(dir.path).then(Backend.fromTransport),
  );
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => dir.deleteSync(recursive: true));
  final app = MaprismaApp(
    key: UniqueKey(),
    connectBackend: () async => backend!,
    windowShots: WindowShots('${dir.path}/shots'),
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

Future<void> openFromHelp(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(const ValueKey('help-open')));
  await settleService(tester);
  await tester.tap(find.byKey(ValueKey('help-tab-$tab')));
  await settleService(tester);
}

void main() {
  testWidgets('leaving Providers and models brings the map up to date', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await openFromHelp(tester, 'Providers and models');
    var before = forcedScans(dir);
    await tester.tap(find.text('Back').last);
    await settleService(tester);
    expect(forcedScans(dir), before, reason: 'nothing changed');

    await openFromHelp(tester, 'Providers and models');
    await tester.tap(find.text('Models (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Load'));
    await settleService(tester);
    before = forcedScans(dir);
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await settleService(tester);
    expect(forcedScans(dir), before, reason: 'still on the page');
    await tester.tap(find.text('Back').last);
    await settleService(tester);
    expect(forcedScans(dir), before + 1);
    await unmountApp(tester);
  });

  testWidgets('leaving the guide leaves it; a page from a box returns there', (
    tester,
  ) async {
    await mountApp(tester);
    await openFromHelp(tester, 'Your first agent');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settleService(tester);
    expect(find.byType(FirstAgentView), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a window blocks the header; Esc leads out of it', (
    tester,
  ) async {
    await mountApp(tester);
    await tester.tap(find.byKey(const ValueKey('help-open')));
    await settleService(tester);
    expect(find.byType(OverlayWindow), findsOneWidget);
    for (final key in ['problems-open', 'map-legend']) {
      expect(
        tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.f5);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f5);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byType(OverlayWindow), findsNothing);
    await unmountApp(tester);
  });

  testWidgets('an open terminal keeps the keyboard and the app its keys', (
    tester,
  ) async {
    await mountApp(tester);
    bool inTerminal() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<TerminalView>() !=
        null;
    final start = find.byKey(const ValueKey('start-agent-test'));
    tester.widget<IconButton>(start).onPressed!();
    await settleService(tester);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(inTerminal(), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleService(tester);
    expect(find.byType(SettingsView), findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await settleService(tester);
    tester.widget<IconButton>(start).onPressed!();
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('terminal-tab-0')));
    await settleService(tester);
    expect(inTerminal(), isTrue);

    await tester.tap(find.byKey(const ValueKey('terminal-screenshot')));
    await settleService(tester);
    await tester.tap(find.text('Done'));
    await settleService(tester);
    expect(inTerminal(), isTrue);
    await unmountApp(tester);
  });

  testWidgets('F9 saves the picture, then asks for its note', (tester) async {
    final dir = await mountApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await settleService(tester);
    await tester.enterText(
      find.byKey(const ValueKey('screenshot-note')),
      'The header is cut off',
    );
    await tester.tap(find.text('Done'));
    await settleService(tester);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final files = Directory('${dir.path}/shots').listSync().map((f) => f.path);
    expect(files.where((f) => f.endsWith('.png')), hasLength(1));
    expect(
      File(files.singleWhere((f) => f.endsWith('.txt'))).readAsStringSync(),
      'The header is cut off\n',
    );
    await unmountApp(tester);
  });

  testWidgets('What we found stays until a preview is applied', (tester) async {
    final dir = await mountApp(
      tester,
      beforeStart: (dir) =>
          File('${dir.path}/found_on_pc').writeAsStringSync(''),
    );
    await tester.tap(find.byKey(const ValueKey('help-open')));
    await settleService(tester);
    await tester.tap(find.text('Find existing AI').first);
    await settleService(tester);
    final reuse = find.byKey(const ValueKey('found-reuse-found:/data/models'));
    await tester.tap(reuse);
    await settleService(tester);
    await tester.tap(find.text('Cancel').last);
    await settleService(tester);
    expect(reuse, findsOneWidget);
    await tester.tap(reuse);
    await settleService(tester);
    await tester.tap(find.text('Apply'));
    await settleService(tester);
    expect(reuse, findsNothing);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'existing.apply')['params'],
      containsPair('plan', 'opaque-existing'),
    );
    await settleService(tester);
    await unmountApp(tester);
  });

  testWidgets(
    'search/files do no inventory refresh; idle surfaces keep updates',
    (tester) async {
      final dir = await mountApp(tester);
      final baseline = forcedScans(dir);
      await openFromHelp(tester, 'Providers and models');
      expect(forcedScans(dir), baseline);
      expect(find.text('Providers and models'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
      await tester.tap(find.text('Models (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Load'));
      await settleService(tester);
      // The page keeps its data; leaving it brings the map up to date.
      expect(forcedScans(dir), baseline);
      expect(find.text('Succeeded'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh))
            .onPressed,
        isNull,
        reason: 'the result window is modal',
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
      await openFromHelp(tester, 'Connections');
      final field = find.byType(TextField);
      await tester.enterText(field, 'Known');
      await tester.tap(find.text('Known server'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, 'Test agent'));
      await settleService(tester);
      expect(find.byType(OverlayWindow), findsOneWidget);
      expect(find.byType(ConnectionsView), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(OverlayWindow),
          matching: find.text('Cancel'),
        ),
      );
      await settleService(tester);
      expect(find.byType(OverlayWindow), findsNothing);
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
      expect(
        find.descendant(
          of: find.byType(OverlayWindow),
          matching: find.widgetWithText(TextButton, 'Undo'),
        ),
        findsOneWidget,
      );
      expect(forcedScans(dir), scans + 1);
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
      expect(find.byType(OverlayWindow), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(OverlayWindow),
          matching: find.text('Cancel'),
        ),
      );
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
      await openFromHelp(tester, 'Providers and models');
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
      await openFromHelp(tester, 'Connections');
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
      await tester.tap(
        find.descendant(
          of: find.byType(OverlayWindow),
          matching: find.text('Cancel'),
        ),
      );
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
  testWidgets('hook to empty opens removal review; Cancel leaves the connection', (
    tester,
  ) async {
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
    final dialog = find.byKey(const ValueKey('disconnect-dialog'));
    expect(dialog, findsOneWidget);
    expect(find.byType(ConnectionReview), findsNothing);
    final move = requests(
      dir,
    ).singleWhere((q) => q['method'] == 'connections.move_preview');
    expect(move['params'], {
      'agent': 'agent:test',
      'old': 'mcp:known-server',
      'new': null,
    });
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('Cancel')),
    );
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'connections.apply').length,
      1,
    );
    await tester.drag(
      find.byTooltip(
        'Move this connection to another compatible box, or to empty space to disconnect.',
      ),
      const Offset(0, 240),
    );
    await settleService(tester);
    File('${dir.path}/no-slots').writeAsStringSync('');
    await tester.tap(find.descendant(of: dialog, matching: find.text('Apply')));
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'connections.apply').length,
      2,
    );
    expect(find.text('Succeeded'), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, 'Undo'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });
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
    await openFromHelp(tester, 'Providers and models');
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
    await openFromHelp(tester, 'Providers and models');
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

  testWidgets('the header shows open problems; one opens the agent', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'health.report'),
      isNotEmpty,
    );
    await tester.tap(find.byKey(const ValueKey('problems-open')));
    await settleService(tester);
    expect(find.text('Test agent: Not signed in'), findsOneWidget);
    expect(
      find.text('Test agent 1.1 is available (you have 1.0)'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Update'));
    await settleService(tester);
    // The agent runs now: nothing starts before the user agrees.
    expect(find.text('Test agent is running right now.'), findsOneWidget);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'updates.run')['params'],
      {'key': 'test'},
    );
    await tester.tap(find.byKey(const ValueKey('update-anyway')));
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'updates.run')['params'],
      {'key': 'test', 'running_ok': true},
    );
    // Update closed the window; the problem is still there to open.
    await tester.tap(find.byKey(const ValueKey('problems-open')));
    await settleService(tester);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('smart-card-agents')),
        matching: find.widgetWithText(OutlinedButton, 'Details'),
      ),
    );
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'agents.health')['params'],
      {'command': 'test'},
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the details of an agent show its health', (tester) async {
    final dir = await mountApp(tester);
    tester
        .widget<AgentMap>(find.byKey(const ValueKey('ai-map')))
        .onAgent('test');
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'agents.health')['params'],
      {'command': 'test'},
    );
    expect(find.text('Needs a look'), findsOneWidget);
    expect(find.text('Select it on the map.'), findsOneWidget);
    // Omarchy's usage record was stale: asked for, then the details again.
    final asked = requests(
      dir,
    ).indexWhere((q) => q['method'] == 'agents.usage_refresh');
    expect(asked, greaterThanOrEqualTo(0));
    expect(
      requests(dir).skip(asked).where((q) => q['method'] == 'agents.details'),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('F1 opens Help: the manual, and a start that closes it', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    expect(find.text('Open user manual'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('help-manual')));
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'help.open_manual'),
      hasLength(1),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Your first agent'));
    await settleService(tester);
    expect(find.text('Open user manual'), findsNothing);
    expect(
      requests(dir).where((q) => q['method'] == 'guide.snapshot'),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('an interrupted download is listed at start and continued', (
    tester,
  ) async {
    final dir = await mountApp(tester, interrupted: true);
    await settleService(tester);
    expect(find.text('m.gguf · Fixture provider'), findsOneWidget);
    expect(
      find.text(
        'Interrupted at {0} · Continue goes on where it stopped'.replaceAll(
          '{0}',
          '40 %',
        ),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Continue'));
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'jobs.continue')['params'],
      {'id': 'aaaaaaaaaaaa'},
    );
    expect(
      requests(dir).where(
        (q) => q['method'] == 'tasks.status' && q['params']['task'] == 'cont',
      ),
      isNotEmpty,
    );
    expect(find.byKey(const ValueKey('job-aaaaaaaaaaaa')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a skill from the web goes through the preview', (tester) async {
    final dir = await mountApp(tester);
    await openFromHelp(tester, 'Connections');
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
    await openFromHelp(tester, 'Connections');
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
    await openFromHelp(tester, 'Connections');
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

  testWidgets('after a provider change the models kept loaded follow', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await openFromHelp(tester, 'Connections');
    unawaited(
      tester.widget<ConnectionsView>(find.byType(ConnectionsView)).onPreview({
        'kind': 'provider',
        'command': 'test',
        'item': 'fixture',
        'remove': false,
      }),
    );
    await settleService(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    // The second preview: the models kept loaded, with its warning.
    expect(
      requests(dir).where((q) => q['method'] == 'models.slots_preview'),
      isNotEmpty,
    );
    expect(
      find.text('Fixture provider keeps 2 models loaded at once'),
      findsOneWidget,
    );
    expect(find.text('Too big together.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-slots'},
    );
    expect(
      requests(dir).where((q) => q['method'] == 'models.slots_reload'),
      hasLength(1),
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
    await openFromHelp(tester, 'Your first agent');
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
    // Chosen from Help, Providers goes back to the map, not the guide.
    await openFromHelp(tester, 'Providers and models');
    await tester.tap(find.text('Back').first);
    await settleService(tester);
    expect(guides(), 3);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('add-on suggestions and updates in Open problems', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'addons.catalog'),
      isNotEmpty,
    ); // read quietly at start, for the hints
    await tester.tap(find.byKey(const ValueKey('problems-open')));
    await settleService(tester);
    expect(find.text('Goose is on this PC but not on the map'), findsOneWidget);
    expect(find.text('Add-on updates ready: Catalog adapter'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Update all'));
    await settleService(tester);
    expect(find.text('2.0 → 2.1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('addons-update-all')));
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'addons.install')['params'],
      {'preview': 'catalog-1'},
    );
    await settleService(tester);
    expect(find.text('Add-ons updated: Catalog adapter'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('problems-open')));
    await settleService(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Get add-ons'));
    await settleService(tester);
    expect(find.byType(MapAddonsFocus), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the app window meets the accessibility guidelines', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await mountApp(tester);
    await settleService(tester);
    Future<void> check({bool overlay = false}) async {
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      // Each text measured on its own. The header's AI Map is left out: the
      // guideline reads 2.34 whatever its colour, so it samples it wrongly.
      await expectLater(
        tester,
        meetsGuideline(
          CustomMinimumContrastGuideline(
            finder: () {
              final texts = find.byWidgetPredicate(
                (w) =>
                    w is Text &&
                    (w.data ?? 'rich').trim().isNotEmpty &&
                    w.data != 'AI Map',
              );
              // What the barrier dims behind the window is not to be read.
              return overlay
                  ? find.descendant(
                      of: find.byType(OverlayWindow),
                      matching: texts,
                    )
                  : texts;
            }(),
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(desktopTapTargets));
    }

    await check(); // the header and the map
    await tester.tap(find.byKey(const ValueKey('problems-open')));
    await settleService(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape); // the status window
    await settleService(tester);
    await tester.tap(find.byTooltip('Settings').first);
    await settleService(tester);
    await check(); // Settings
    await tester.tap(find.byKey(const ValueKey('help-open')));
    await settleService(tester);
    await check(overlay: true); // Help
    await tester.sendKeyEvent(LogicalKeyboardKey.escape); // Esc closes it
    await settleService(tester);
    expect(find.byKey(const ValueKey('help-manual')), findsNothing);
    expect(tester.takeException(), isNull);
    semantics.dispose();
    await unmountApp(tester);
  });

  testWidgets('keyboard shortcuts: Ctrl+, F5, zoom, Esc and Backspace', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    final settings = find.byType(SettingsView);
    Future<void> keys(LogicalKeyboardKey key, {bool control = false}) async {
      if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(key);
      if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await settleService(tester);
    }

    await keys(LogicalKeyboardKey.comma, control: true);
    expect(settings, findsOneWidget);
    await keys(LogicalKeyboardKey.backspace);
    expect(settings, findsNothing);
    await keys(LogicalKeyboardKey.comma, control: true);
    expect(settings, findsOneWidget);
    await keys(LogicalKeyboardKey.escape);
    expect(settings, findsNothing);

    final before = requests(dir).length;
    await keys(LogicalKeyboardKey.f5);
    expect(requests(dir).length, greaterThan(before));

    double scale() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer).first)
        .transformationController!
        .value
        .entry(0, 0);
    await keys(LogicalKeyboardKey.equal, control: true);
    expect(scale(), closeTo(1.25, 1e-9));
    await keys(LogicalKeyboardKey.minus, control: true);
    await keys(LogicalKeyboardKey.minus, control: true);
    expect(scale(), closeTo(0.8, 1e-9));
    await keys(LogicalKeyboardKey.digit0, control: true);
    expect(scale(), 1);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('recent changes in Settings: Undo after a restart', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.tap(find.byTooltip('Settings').first);
    await settleService(tester);
    final undo = find.byKey(const ValueKey('undo-20261030-100000-000000'));
    await tester.scrollUntilVisible(
      undo,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(undo);
    await tester.pumpAndSettle();
    expect(find.text('~/.claude.json'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('undo-20261029-090000-000000')),
      findsNothing,
    ); // changed again since: nothing to undo
    await tester.tap(undo);
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'changes.undo')['params'],
      {'id': '20261030-100000-000000'},
    );
    expect(find.text('Put back: ~/.claude.json'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the desktop theme follows also while the app is busy', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    Color primary() => tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .colorScheme
        .primary;
    final before = primary();
    await tester.tap(find.byTooltip('Settings').first);
    await settleService(tester);
    final undo = find.byKey(const ValueKey('undo-20261030-100000-000000'));
    await tester.scrollUntilVisible(
      undo,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(undo);
    await tester.pumpAndSettle();
    File('${dir.path}/slow').writeAsStringSync('');
    await tester.tap(undo); // busy until the core answers
    await settleService(tester);
    File(
      '${dir.path}/theme.json',
    ).writeAsStringSync(jsonEncode({'accent': '#d03030'}));
    await tester.pump(const Duration(seconds: 2)); // the next theme tick
    await settleService(tester);
    expect(primary(), isNot(before)); // followed while busy
    File('${dir.path}/release').writeAsStringSync('');
    await settleService(tester);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('settings changed by another process show without a refresh', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.tap(find.byTooltip('Settings').first);
    await settleService(tester);
    final daily = find.byKey(const ValueKey('ai-checks'));
    await tester.scrollUntilVisible(
      daily,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<SwitchListTile>(daily).value, isFalse);
    File(
      '${dir.path}/other.json',
    ).writeAsStringSync(jsonEncode({'ai_checks': true}));
    await tester.pump(const Duration(seconds: 2)); // the next check
    await settleService(tester);
    expect(tester.widget<SwitchListTile>(daily).value, isTrue);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('popup mode on Omarchy: placed when shown, Esc closes it', (
    tester,
  ) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (call) async {
        calls.add(call.method);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final dir = await mountApp(
      tester,
      beforeStart: (d) {
        File('${d.path}/omarchy').writeAsStringSync('');
        File('${d.path}/window_popup').writeAsStringSync('');
      },
    );
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'window.popup').first['params'],
      {'width': 1100, 'height': 760},
    ); // floated under the bar at start
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await settleService(tester);
    expect(calls, isNot(contains('hide'))); // Backspace never closes it
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(calls, contains('hide'));
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('Omarchy by default: an ordinary window', (tester) async {
    final dir = await mountApp(
      tester,
      beforeStart: (d) {
        File('${d.path}/omarchy').writeAsStringSync('');
      },
    );
    await settleService(tester);
    expect(requests(dir).where((q) => q['method'] == 'window.popup'), isEmpty);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a normal window elsewhere: Esc on the main page stays', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(requests(dir).where((q) => q['method'] == 'window.popup'), isEmpty);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the daily AI checks\' MCP updates in the MCP smart card', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    expect(
      requests(
        dir,
      ).firstWhere((q) => q['method'] == 'checks.mcp_check')['params'],
      {'force': false},
    ); // the daily check, asked quietly at start
    await tester.tap(find.byKey(const ValueKey('smart-status-mcp')));
    await settleService(tester);
    expect(
      find.text('MCP server fetch 1.5.0 is available (you have 1.4.2)'),
      findsOneWidget,
    );
    expect(find.text('Faster.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-release-fetch')));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'checks.mcp_release')['params'],
      {'name': 'fetch'},
    );
    await tester.tap(find.byKey(const ValueKey('mcp-task-fetch')));
    await settleService(tester);
    expect(find.textContaining('pinned to 1.4.2'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'system.help_apply'),
      isEmpty,
    ); // nothing starts without Continue
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('a program found on this PC is added through the form', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('smart-status-mcp')));
    await settleService(tester);
    expect(find.text('New on this PC: wordcraft'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add MCP server…'));
    await settleService(tester);
    expect(find.byKey(const ValueKey('found-panel')), findsOneWidget);
    expect(find.text('★ new · ~/.local/bin/wordcraft-cli'), findsOneWidget);
    expect(
      find.text('1 AppImage not looked into yet (wordcraft.AppImage).'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Look inside…'));
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'found.look_inside'),
      hasLength(1),
    );
    expect(find.byKey(const ValueKey('found-panel')), findsOneWidget);
    // Inside an AppImage: unpacked first, after a yes.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('found-mcp-vectorcraft 1.2.0')),
        matching: find.byType(OutlinedButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Unpacks vectorcraft.AppImage into'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('found-unpack')));
    await settleService(tester);
    expect(
      requests(dir).lastWhere((q) => q['method'] == 'found.unpack')['params'],
      {'program': '/h/Applications/vectorcraft-1.2.0/usr/bin/vectorcraft-cli'},
    );
    expect(
      find.widgetWithText(
        TextFormField,
        '/h/Applications/vectorcraft-1.2.0/usr/bin/vectorcraft-cli',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('found-open')));
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'found.seen').length,
      greaterThanOrEqualTo(2),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('found-mcp-wordcraft')),
        matching: find.byType(OutlinedButton),
      ),
    );
    await settleService(tester);
    expect(find.byKey(const ValueKey('found-panel')), findsNothing);
    expect(find.widgetWithText(TextFormField, 'wordcraft'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, '/h/.local/bin/wordcraft-cli'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('an app update moves its users to the newer version', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('smart-status-mcp')));
    await settleService(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add MCP server…'));
    await settleService(tester);
    expect(find.text('gridcraft  0.7.0 → 0.8.0'), findsOneWidget);
    expect(find.text('↑ Update · used by Claude Code'), findsOneWidget);
    final scans = requests(
      dir,
    ).where((q) => q['method'] == 'found.scan').length;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Update…'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'found.update_preview')['params'],
      {'program': '/h/Applications/gridcraft-0.8.0/usr/bin/gridcraft-cli'},
    );
    expect(find.text('~/Applications/gridcraft-0.7.0/'), findsOneWidget);
    expect(
      find.text(
        'The old version is kept with the backup for 7 days: Undo brings everything back.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await settleService(tester);
    expect(
      requests(
        dir,
      ).lastWhere((q) => q['method'] == 'connections.apply')['params'],
      {'plan': 'opaque-update'},
    );
    await settleService(tester);
    expect(
      requests(dir).where((q) => q['method'] == 'found.scan').length,
      greaterThan(scans),
    ); // looked again: the update is done
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('AI Map leads back from the agent list on Help', (tester) async {
    await mountApp(tester);
    await settleService(tester);
    final map = find.byKey(const ValueKey('details-agent:test'));
    expect(map, findsOneWidget);
    await openFromHelp(tester, 'Agents');
    expect(find.text('Select an agent'), findsOneWidget);
    expect(map, findsNothing);
    await tester.tap(find.text('AI Map'));
    await settleService(tester);
    expect(find.text('Select an agent'), findsNothing);
    expect(map, findsOneWidget);
    // Tapping the map it already shows changes nothing.
    await tester.tap(find.text('AI Map'));
    await settleService(tester);
    expect(map, findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('Back, Esc and Backspace lead from details to the map', (
    tester,
  ) async {
    await mountApp(tester);
    await settleService(tester);
    final details = find.byKey(const ValueKey('details-agent:test'));
    final stepsBack = <Future<void> Function()>[
      () => tester.tap(find.text('Back')),
      () => tester.sendKeyEvent(LogicalKeyboardKey.escape),
      () => tester.sendKeyEvent(LogicalKeyboardKey.backspace),
    ];
    for (final back in stepsBack) {
      await tester.tap(details);
      await settleService(tester);
      expect(find.text('Back'), findsOneWidget);
      await back();
      await settleService(tester);
      expect(find.text('Select an agent'), findsNothing);
      expect(details, findsOneWidget);
    }
    await unmountApp(tester);
  });

  testWidgets(
    'agent card controls show Usage, Details in menu, and red Stop only while running',
    (tester) async {
      final dir = await mountApp(tester);
      await settleService(tester);

      // When idle, Stop is not shown; Details and Usage symbols are shown.
      expect(find.byKey(const ValueKey('stop-agent-test')), findsNothing);
      expect(find.byKey(const ValueKey('details-agent:test')), findsOneWidget);
      expect(find.byKey(const ValueKey('usage-agent-test')), findsOneWidget);

      // Usage symbol opens the agent's usage dialog.
      await tester.tap(find.byKey(const ValueKey('usage-agent-test')));
      await settleService(tester);
      expect(find.text('Usage · Test agent'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await settleService(tester);

      // Card menu uses "Details" instead of "Open".
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('Test agent'),
                matching: find.byType(Card),
              )
              .first,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Details'), findsOneWidget);
      expect(find.text('Open'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // When the agent runs, the red Stop symbol appears and stops the external instance.
      File('${dir.path}/agent_running').writeAsStringSync('1');
      await tester.tap(find.byTooltip('Refresh'));
      await settleService(tester);
      expect(find.byKey(const ValueKey('stop-agent-test')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('stop-agent-test')));
      await settleService(tester);
      expect(find.text('Stop external instance'), findsOneWidget);
      expect(find.text('PID 42'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settleService(tester);
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'every finding from health.report appears in its column\'s smart card',
    (tester) async {
      await mountApp(
        tester,
        beforeStart: (d) {
          File('${d.path}/health.json').writeAsStringSync(
            jsonEncode({
              'warn': 1,
              'hint': 3,
              'level': 'warn',
              'summary': '1 thing to fix · 3 tips',
              'open_text': '1 open problem',
              'areas': [
                {
                  'key': 'connections',
                  'title': 'MCP servers and skills',
                  'icon': '',
                  'findings': [
                    {
                      'level': 'hint',
                      'column': 'mcp',
                      'title': 'MCP finding in column 0',
                      'text': '',
                      'action': ['addmcp'],
                    },
                  ],
                },
                {
                  'key': 'agents',
                  'title': 'Agents',
                  'icon': '',
                  'findings': [
                    {
                      'level': 'warn',
                      'column': 'agents',
                      'title': 'Agent finding in column 1',
                      'text': '',
                      'action': ['details', 'test'],
                    },
                  ],
                },
                {
                  'key': 'local',
                  'title': 'Local LLMs',
                  'icon': '',
                  'findings': [
                    {
                      'level': 'hint',
                      'column': 'providers',
                      'title': 'Provider finding in column 2',
                      'text': '',
                      'action': ['runtime', 'fixture'],
                    },
                    {
                      'level': 'hint',
                      'column': 'models',
                      'title': 'Model finding in column 3',
                      'text': '',
                      'action': ['models', 'fixture'],
                    },
                  ],
                },
              ],
              'uses': [],
            }),
          );
        },
      );
      await settleService(tester);

      for (final (col, expected) in const [
        ('mcp', 'MCP finding in column 0'),
        ('agents', 'Agent finding in column 1'),
        ('providers', 'Provider finding in column 2'),
        ('models', 'Model finding in column 3'),
      ]) {
        await tester.tap(find.byKey(ValueKey('smart-status-$col')));
        await settleService(tester);
        expect(find.text(expected), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settleService(tester);
      }
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'a hidden column with a red problem turns the header symbol red, and clicking it reveals and opens that column\'s smart card on status',
    (tester) async {
      await mountApp(
        tester,
        beforeStart: (d) {
          File('${d.path}/health.json').writeAsStringSync(
            jsonEncode({
              'warn': 1,
              'hint': 0,
              'level': 'warn',
              'summary': '1 thing to fix',
              'open_text': '1 open problem',
              'areas': [
                {
                  'key': 'local',
                  'title': 'Local LLMs',
                  'icon': '',
                  'findings': [
                    {
                      'level': 'warn',
                      'column': 'models',
                      'title': 'Hidden model problem',
                      'text': 'Fix model folder.',
                      'action': ['models', 'fixture'],
                    },
                  ],
                },
              ],
              'uses': [],
            }),
          );
        },
      );
      await settleService(tester);

      // Hide Models column (column 3) via the filter chip.
      await tester.tap(find.byKey(const ValueKey('map-column-3')));
      await settleService(tester);
      expect(find.byKey(const ValueKey('smart-card-models')), findsNothing);

      // Header status icon still has level 2 (red warn) because of the hidden column.
      final headerIcon = tester.widget<SmartStatusIcon>(
        find.descendant(
          of: find.byKey(const ValueKey('problems-open')),
          matching: find.byType(SmartStatusIcon),
        ),
      );
      expect(headerIcon.level, 'warn');

      // Clicking the header symbol reveals Models and opens its smart card on the status list.
      await tester.tap(find.byKey(const ValueKey('problems-open')));
      await settleService(tester);
      expect(find.byKey(const ValueKey('smart-card-models')), findsOneWidget);
      expect(find.text('Hidden model problem'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await unmountApp(tester);
    },
  );

  testWidgets('an open Ask AI window holds the keys; Update closes it', (
    tester,
  ) async {
    final dir = await mountApp(tester);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('smart-status-agents')));
    await settleService(tester);
    expect(find.byType(OverlayWindow), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('smart-rules')));
    await settleService(tester);
    expect(find.byType(ActionRulesWindow), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rule-back')));
    await settleService(tester);
    expect(find.byType(ActionRulesWindow), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    expect(find.byKey(const ValueKey('help-manual')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    expect(find.byType(OverlayWindow), findsNothing);
    // The header works again.
    await tester.sendKeyEvent(LogicalKeyboardKey.f1);
    await settleService(tester);
    expect(find.byKey(const ValueKey('help-manual')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settleService(tester);
    await tester.tap(find.byKey(const ValueKey('smart-status-agents')));
    await settleService(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Update').first);
    await settleService(tester);
    expect(find.byType(OverlayWindow), findsNothing);
    expect(requests(dir).any((q) => q['method'] == 'updates.run'), isTrue);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the use cases stay reachable in Help', (tester) async {
    await mountApp(tester);
    await settleService(tester);
    await openFromHelp(tester, 'What you can do with it');
    expect(find.byKey(const ValueKey('use-coding')), findsOneWidget);
    expect(find.text('Vibe coding'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });

  testWidgets('the use cases appear on the welcome page', (tester) async {
    await mountApp(tester, welcome: true);
    await settleService(tester);
    expect(find.text('What you can do with it'), findsOneWidget);
    expect(find.byKey(const ValueKey('use-coding')), findsOneWidget);
    expect(find.text('Vibe coding'), findsOneWidget);
    expect(find.text('Almost'), findsOneWidget);
    expect(find.text('✓ Test agent'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmountApp(tester);
  });
}
