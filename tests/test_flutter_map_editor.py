import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

import agents
import connect
import flutter_connections
import flutter_map_editor as api
import flutter_map_payload
import flutter_plan_wire
import flutter_worker
import graph
import inventory


class MapEditorTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.file = self.root / 'config'
        self.file.write_text('private-fixture')
        self.connections = flutter_connections.Connections(self.root / 'backups')
        self.runtimes = [inventory.Runtime(k, k, installed=True, models=['old', 'new']) for k in ('r', 's')]
        self.catalog = [agents.Agent(c, c, '', installed=True) for c in ('a', 'b')]
        self.graph = {'nodes': [dict(id=i, kind=k, label=label) for i,k,label in (
            ('agent:a','agent','a'), ('agent:b','agent','b'), ('runtime:r','runtime','r'), ('runtime:s','runtime','s'),
            ('model:r:old','model','old'), ('model:r:new','model','new'), ('mcp:test','mcp','test'))],
            'edges': [dict(source=s,target=t,kind=k) for s,t,k in (
                ('agent:a','runtime:r','uses'), ('agent:a','mcp:test','mcp'),
                ('runtime:r','model:r:old','serves'), ('runtime:r','model:r:new','serves'),
                ('agent:a','model:r:old','default'))]}
        for target, value in ((('agents','list_agents'), self.catalog), (('inventory','collect'), inventory.Inventory(runtimes=self.runtimes)),
                              (('connect','KEYS'), {'r':'r-local','s':'s-local'}), (('connect','SUPPORTED'),('a','b')),
                              (('connect','FIXED'),{})):
            module = {'agents':agents,'inventory':inventory,'connect':connect}[target[0]]
            patch = mock.patch.object(module,target[1],return_value=value) if callable(getattr(module,target[1])) else mock.patch.object(module,target[1],value)
            patch.start();self.addCleanup(patch.stop)
        self.engine = mock.patch.object(api.llm_engine,'of',return_value=SimpleNamespace(can_load=False)).start()
        self.addCleanup(mock.patch.stopall)
        self.fresh = mock.patch.object(graph,'build',return_value=SimpleNamespace(edges=[SimpleNamespace(**e) for e in self.graph['edges']])).start()
        mock.patch('agent_details.details_for',return_value=SimpleNamespace(model='old')).start()

    def preview(self, method, params):
        return api.preview(method,params,self.graph,self.connections,self.root/'settings.json')

    def plan(self, command='a'):
        old = connect._read(self.file)
        return connect.Plan(command,'','',changes=[connect.Change(self.file,old,old+'!')])

    def test_move_is_one_plan_one_backup_and_undo(self):
        with mock.patch.object(connect,'is_connected',return_value=True), mock.patch.object(connect,'plan',side_effect=lambda *a,**k:self.plan()) as build:
            result = self.preview('connections.move_preview',dict(agent='agent:a',old='runtime:r',new='runtime:s'))
        build.assert_called_once_with('a',self.runtimes[1],'',False,replaces=self.runtimes[0])
        self.assertNotIn('private-fixture',json.dumps(result))
        applied = self.connections.apply(result['plan'])
        self.assertEqual(self.file.read_text(),'private-fixture!')
        self.connections.undo(applied['undo'])
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_stale_move_or_unknown_source_rejected_without_changes(self):
        with mock.patch.object(connect,'is_connected',return_value=False), mock.patch.object(connect,'plan') as build:
            for changes in ({},{'agent':'agent:unknown'},{'new':'mcp:test'},{'old':'runtime:s'}):
                with self.subTest(changes=changes), self.assertRaises(ValueError):
                    self.preview('connections.move_preview',dict(agent='agent:a',old='runtime:r',new='runtime:s')|changes)
        build.assert_not_called()
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_remove_unapplied_failure_only_changes_metadata_and_undo_restores(self):
        path = self.root/'failed-links.json'
        text = json.dumps({'agent:a|mcp:test':{'kind':'mcp','applied':False,'hints':[{'level':'error','text':'test'}]}})
        path.write_text(text)
        with mock.patch.object(api.mcp_ctl,'plan') as build:
            result=self.preview('connections.move_preview',dict(agent='agent:a',old='mcp:test',new=None))
        build.assert_not_called()
        applied=self.connections.apply(result['plan'])
        self.assertEqual(json.loads(path.read_text()),{})
        self.connections.undo(applied['undo'])
        self.assertEqual(path.read_text(),text)

    def test_repair_updates_configuration_and_clears_hints_in_one_undo(self):
        path=self.root/'failed-links.json'
        text=json.dumps({'agent:a|mcp:test':{'kind':'mcp','applied':False,'hints':[{'level':'error','text':'test'}]}})
        path.write_text(text)
        def preview(_):
            return self.connections.keep(self.plan())
        with mock.patch.object(self.connections,'preview',side_effect=preview):
            result=api.repair_preview({'agent':'agent:a','target':'mcp:test'},self.graph,self.connections,self.root/'settings.json')
        applied=self.connections.apply(result['plan'])
        self.assertEqual(json.loads(path.read_text()),{})
        self.assertEqual(self.file.read_text(),'private-fixture!')
        self.connections.undo(applied['undo'])
        self.assertEqual(path.read_text(),text)
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_failure_metadata_changed_since_preview_is_preserved(self):
        path=self.root/'failed-links.json'
        path.write_text(json.dumps({'agent:a|mcp:test':{'kind':'mcp','applied':False,'hints':[{'level':'error','text':'test'}]}}))
        result=self.preview('connections.move_preview',dict(agent='agent:a',old='mcp:test',new=None))
        path.write_text('{}')
        with self.assertRaises(RuntimeError):self.connections.apply(result['plan'])
        self.assertEqual(path.read_text(),'{}')

    def test_attach_many_agents_merges_shared_file_sequentially(self):
        with mock.patch.object(connect,'plan',side_effect=lambda c,*a,**k:self.plan(c)):
            result=self.preview('models.attach_preview',dict(provider='runtime:r',model='model:r:new',agents=['a','b']))
        self.assertEqual(result['agents'],['a','b'])
        applied=self.connections.apply(result['plan'])
        self.assertEqual(self.file.read_text(),'private-fixture!!')
        self.connections.undo(applied['undo'])
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_switch_rejects_changed_users(self):
        self.fresh.return_value=SimpleNamespace(edges=[])
        with mock.patch.object(connect,'plan') as build, self.assertRaisesRegex(ValueError,'users changed'):
            self.preview('models.switch_preview',dict(provider='runtime:r',old='model:r:old',new='model:r:new'))
        build.assert_not_called()

    def test_switch_rejects_running_model_user(self):
        self.engine.return_value=SimpleNamespace(can_load=True)
        with mock.patch.object(connect,'is_active',return_value=True), mock.patch.object(connect,'plan',return_value=self.plan()), \
                mock.patch.object(api.provider_watch,'agent_instances',return_value={'a':[[]]}), self.assertRaisesRegex(ValueError,'in use'):
            self.preview('models.switch_preview',dict(provider='runtime:r',old='model:r:old',new='model:r:new'))

    def test_model_only_load_is_not_empty_and_requires_worker(self):
        self.engine.return_value=SimpleNamespace(can_load=True)
        result=self.preview('models.attach_preview',dict(provider='runtime:r',model='model:r:new',agents=[]))
        self.assertFalse(result['empty'])
        self.assertEqual(result['model_actions'],[{'operation':'model.load','model':'new'}])
        with self.assertRaises(ValueError):self.connections.apply(result['plan'])

    def test_hostile_requests_and_duplicate_agents_are_refused(self):
        for params in ({'provider':'runtime:r','model':'model:r:new','agents':['a','a']},
                       {'provider':'runtime:r','model':'model:r:new','agents':[{}]},
                       {'provider':'runtime:r','model':'model:r:new','agents':[],'command':'sh'},
                       {'provider':'runtime:s','model':'model:r:new','agents':['a']}):
            with self.subTest(params=params),self.assertRaises(ValueError):self.preview('models.attach_preview',params)

    def test_layout_bounds_reject_non_finite_bool_and_unexpected_fields(self):
        for value in (None,[],{'commands':[]},{'pins':['a','a']},{'cards':{'x':[True,0]}},
                      {'cards':{'x':[float('nan'),0]}},{'cards':{'x':[0,30001]}},{'order':{'x':[{}]}}):
            with self.subTest(value=value):self.assertFalse(api.valid_layout(value))
        self.assertTrue(api.valid_layout({'cards':{'x':[0,30000]},'order':{'x':['a']},'collapsed':['x'],'pins':['a']}))

    def test_wire_v3_validates_actions_and_keeps_v1_v2_compatibility(self):
        p=self.plan();p.model_actions=[{'operation':'model.load','key':'r','model':'new','agents':[]}]
        body=flutter_plan_wire.encode(p,self.root)
        self.assertEqual(flutter_plan_wire.decode(body)[0].model_actions,p.model_actions)
        record=json.loads(body)
        for version in (1,2):
            old={k:v for k,v in record.items() if k!='model_actions' and (version!=1 or k not in ('links_add','links_remove'))}
            old['version']=version
            self.assertEqual(flutter_plan_wire.decode(json.dumps(old).encode())[0].model_actions,[])
        for bad in ({'operation':'exec'}, {'operation':'model.load','key':'r','model':'new','agents':[{}]}):
            with self.assertRaises(ValueError):flutter_plan_wire.decode(json.dumps(record|{'model_actions':[bad]}).encode())

    def test_worker_rechecks_actions_before_any_file_write(self):
        p=self.plan();p.model_actions=[{'operation':'model.load','key':'r','model':'new','agents':[]}]
        with mock.patch.object(api,'validate_actions',side_effect=ValueError('stale')),self.assertRaises(ValueError):
            flutter_worker.execute_private('connections.apply',flutter_plan_wire.encode(p,self.root/'backups'),lambda *_:None)
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_api_failure_keeps_backup_and_undo(self):
        p=self.plan();p.model_actions=[{'operation':'model.load','key':'r','model':'new','agents':[]}]
        with mock.patch.object(api,'validate_actions',return_value=p.model_actions),mock.patch('flutter_providers.execute',side_effect=RuntimeError):
            result=flutter_worker.execute_private('connections.apply',flutter_plan_wire.encode(p,self.root/'backups'),lambda *_:None)
        self.assertEqual(result['context_failures'],1)
        public=self.connections.register_backup(result)
        self.connections.undo(public['undo'])
        self.assertEqual(self.file.read_text(),'private-fixture')

    def test_activity_and_bounded_failure_hints(self):
        g=graph.Graph(nodes=[graph.Node('agent:a',1,'a'),graph.Node('runtime:r',2,'r')],
                      edges=[graph.Edge('agent:a','runtime:r','uses')])
        failure={'agent:a|runtime:r':{'applied':False,'hints':[{'level':'error','text':'test'}]}}
        rows=flutter_map_payload.edges(g,{'a':{'working':True}},failure,inventory.Inventory(),'agents')
        self.assertTrue(rows[0]['active']);self.assertEqual(rows[0]['activity'],'agent')
        self.assertEqual(rows[0]['hints'],failure['agent:a|runtime:r']['hints'])
        self.assertFalse(flutter_map_payload.edges(g,{'a':{'working':True}},failure,inventory.Inventory(),'off')[0]['active'])
