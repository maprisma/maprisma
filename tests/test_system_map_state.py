"""Saved map, strict first-use scans, missing mounts and worker routing."""
import copy
import json
import os
from pathlib import Path
import stat
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import flutter_system_map as system
import system_map_cache as cache
import system_tools


def facts(mounts=(),nodes=(),searched=False):
    root={'id':'pc','kind':'hardware','path':'','label':'This PC','detail':'Linux','info':'','status':'','column':0}
    return {'version':1,'checked_at':time.time(),'nodes':[root,*nodes],'edges':[],'notes':[],
            'helpers':[],'limited':False,'mounts':list(mounts),'records':[],'search_done':searched,'health':[]}


class StateTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.settings=self.root/'settings.json'
        self.path=cache.location(self.settings)
        self.disk=self.root/'disk';self.disk.mkdir()
        self.mount={'path':str(self.disk),'filesystem':'ext4','identity':'1:8:2'}

    def test_saved_map_loads_without_any_scan_and_is_private(self):
        cache.save(self.path,facts([self.mount]))
        with patch('existing_ai.scan',side_effect=AssertionError('disk scan')),patch('system_tools.hardware',side_effect=AssertionError('hardware scan')):
            self.assertEqual(cache.load(self.path)['mounts'],[self.mount])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode),0o600)

    def test_bad_cache_types_size_mode_and_links_are_rejected(self):
        self.path.write_text('invalid');self.path.chmod(0o600)
        self.assertEqual(cache.load(self.path),{})
        self.path.write_text('x'*(cache.MAX_BYTES+1));self.assertEqual(cache.load(self.path),{})
        cache.save(self.path,facts());self.path.chmod(0o644);self.assertEqual(cache.load(self.path),{})
        self.path.unlink();outside=self.root/'other';outside.write_text('{}');self.path.symlink_to(outside)
        self.assertEqual(cache.load(self.path),{})
        self.path.unlink();os.mkfifo(self.path);self.assertEqual(cache.load(self.path),{})

    def test_skip_and_repeat_visit_never_search(self):
        cache.save(self.path,facts([self.mount],searched=False))
        with patch('flutter_system_map.snapshot',side_effect=lambda *a,**k:facts([self.mount])),patch('existing_ai.scan',side_effect=AssertionError('search after Skip')):
            result=system.refresh(self.settings,False)
        self.assertFalse(result['search_done'])

    def test_cheap_refresh_keeps_missing_disk_and_folder(self):
        node=lambda ident,path,kind,col:{'id':ident,'kind':kind,'path':path,'label':ident,'detail':path,'info':'','status':'found','column':col}
        old=facts([self.mount],[node('disk:'+str(self.disk),str(self.disk),'disk',1),node('folder:x',str(self.disk/'models'),'folder',4)],True)
        cache.save(self.path,old)
        with patch('flutter_system_map.snapshot',return_value=facts()),patch('existing_ai.scan',side_effect=AssertionError('cheap search')):
            result=system.refresh(self.settings,False)
        self.assertEqual({n['status'] for n in result['nodes'] if n['id']!='pc'},{'missing'})
        self.assertIn(self.mount,result['mounts'])

    def test_new_mount_search_only_after_opt_in_first_search(self):
        cache.save(self.path,facts([],searched=True))
        found={'records':[],'limits':[],'depth':5,'notices':[],'foreign':[]}
        with patch('flutter_system_map.snapshot',return_value=facts([self.mount])),patch('existing_ai.scan',return_value=found) as scan:
            system.refresh(self.settings,False)
        scan.assert_called_once_with(str(self.disk))

    def test_full_scan_is_per_mount_and_sizes_are_not_in_cheap_refresh(self):
        found={'records':[],'limits':['depth'],'depth':5,'notices':[],'foreign':[]}
        with patch('flutter_system_map.snapshot',return_value=facts([self.mount])),patch('existing_ai.scan',return_value=found) as scan,patch('disk_usage.measure') as size:
            result=system.refresh(self.settings,True)
        scan.assert_called_once();size.assert_called_once()
        self.assertTrue(result['search_done'])
        self.assertEqual(result['scan_limits'][0]['limits'],['depth'])
        cache.save(self.path,result)
        with patch('flutter_system_map.snapshot',return_value=facts([self.mount])),patch('existing_ai.scan',side_effect=AssertionError()),patch('disk_usage.measure',side_effect=AssertionError()):
            system.refresh(self.settings,False)

    def test_first_use_snapshot_does_not_spawn_or_use_network(self):
        with patch('subprocess.Popen',side_effect=AssertionError('program run')),patch('socket.socket',side_effect=AssertionError('network')):
            result=system.snapshot(self.settings)
        self.assertEqual(result['version'],1)
        self.assertTrue(any(n['kind']=='hardware' for n in result['nodes']))

    def test_tool_versions_are_read_without_running_binaries(self):
        bin_dir=self.root/'bin';bin_dir.mkdir()
        executable=bin_dir/'python3.14';executable.write_text('fixture');executable.chmod(0o755)
        (bin_dir/'python3').symlink_to(executable.name)
        with patch('subprocess.Popen',side_effect=AssertionError('version probe')),patch('agents.package_version',return_value=None):
            rows=system_tools.detect(True,{'PATH':str(bin_dir)})
        row=next(r for r in rows if r['key']=='python')
        self.assertEqual(row['version'],'3.14')
        self.assertEqual(row['target'],str(executable))

    def test_newer_analysis_and_view_survive_background_save(self):
        saved=facts();saved['analysis']={'when':'2026-10-28T01:00:00','summary':'new','agent':'fixture','findings':[]}
        saved['view']={'selected':'pc','transform':[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}
        cache.save(self.path,saved)
        stale=facts();stale['analysis']=None
        cache.save(self.path,stale)
        self.assertEqual(cache.load(self.path)['analysis']['summary'],'new')
        self.assertEqual(cache.load(self.path)['view']['selected'],'pc')

    def test_all_new_private_worker_operations_are_routed_explicitly(self):
        import flutter_worker
        for operation,module,name in (
            ('system.analyze','system_map_analysis','analyze'),('system.tool_check','system_tools','check'),
            ('system.move_preview','system_moves','prepare'),('system.move_apply','system_moves','execute'),('system.move_undo','system_moves','undo')):
            with self.subTest(operation=operation),patch('flutter_worker.AdapterRegistry'),patch(module+'.'+name,return_value={'routed':operation}) as run:
                result=flutter_worker.execute_private(operation,json.dumps({'settings_path':None,'undo':'x'}).encode(),lambda *a:None)
            self.assertEqual(result,{'routed':operation});run.assert_called_once()
        with self.assertRaises(ValueError):flutter_worker.execute_private('shell.exec',b'{}',lambda *a:None)

    def test_cached_analysis_unknown_node_goes_to_general_and_exact_prompt_is_sent(self):
        import system_map_analysis
        cache.save(self.path,facts())
        answer=json.dumps({'summary':'Checked','findings':[{'level':'tip','title':'one','detail':'detail','node':'pc'}, {'level':'tip','title':'two','detail':'detail','node':'unknown'}]})
        record={'command':'fixture','prompt':'EXACT REVIEWED PROMPT','cache_path':str(self.path),'settings_path':str(self.settings),'nodes':['pc']}
        with patch('flutter_addons.AdapterRegistry'),patch('agents.list_agents',return_value=[SimpleNamespace(command='fixture',installed=True)]),patch('ai_helper.helpers',return_value=['fixture']),patch('ai_helper.look_up',return_value=answer) as lookup:
            result=system_map_analysis.analyze(json.dumps(record).encode())
        self.assertEqual(lookup.call_args.args[2],record['prompt'])
        self.assertEqual([f['node'] for f in result['analysis']['findings']],['pc',''])
        self.assertEqual(cache.load(self.path)['analysis']['summary'],'Checked')

    def test_detected_runtime_alias_keeps_discovery_actions(self):
        from flutter_backend import Service
        executable=self.disk/'server';executable.write_text('fixture')
        alias=self.root/'server';alias.symlink_to(executable)
        service=Service(self.settings)
        row={'path':str(executable),'provider':'fixture','found':'opaque','kind':'runtime'}
        data=facts(nodes=[{'id':'runtime:fixture','kind':'runtime','path':str(alias),'label':'Fixture','detail':'','info':'','status':'stopped','column':2}])
        with patch.object(service.existing,'register',return_value={'items':[row]}):
            public=service.system_public(data)
        runtime=next(n for n in public['nodes'] if n['kind']=='runtime')
        self.assertEqual(runtime['found'],'opaque')
        self.assertEqual(runtime['provider'],'fixture')
        self.assertNotIn('records',public)

    def test_missing_disk_note_is_not_duplicated(self):
        note='A model folder is unavailable. Check its mount before downloading again.'
        old=facts([self.mount], searched=True)
        cache.save(self.path, old)
        fresh=facts(); fresh['notes']=[note]
        with patch('flutter_system_map.snapshot',return_value=fresh):
            result=system.refresh(self.settings)
        self.assertEqual(result['notes'].count(note),1)

    def test_forget_disk_changes_only_cache_and_preserves_nested_mount(self):
        child={**self.mount,'path':str(self.disk/'nested'),'identity':'nested'}
        def node(path):
            return {'id':'disk:'+path,'kind':'disk','path':path,'label':path,'detail':'','info':'','status':'missing','column':1}
        folder={**node(str(self.disk/'models')),'id':'folder:gone','kind':'folder','column':4}
        old=facts([self.mount,child],[node(str(self.disk)),node(child['path']),folder],True)
        old['edges']=[{'source':'disk:'+str(self.disk),'target':'folder:gone'}]
        def record(path,mount):
            return {'path':path,'provider':'','kind':'models','name':'GGUF','mount':mount,'count':1,'stamps':{},'dependencies':[],'environment':{}}
        old['records']=[record(str(self.disk/'models'),self.mount),record(child['path']+'/models',child)]
        old['move_undo']='keep-journal'
        old['analysis']={'summary':'Keep summary','when':'today','agent':'fixture','findings':[{'id':'a','node':'folder:gone','title':'x','detail':'x','level':'tip'}]}
        self.settings.write_text('{"model_folders":["keep"]}')
        sentinel=self.disk/'keep-model.gguf';sentinel.write_bytes(b'model')
        cache.save(self.path,old)
        service=system.SystemMap(self.settings)
        with patch('existing_ai.mounts',return_value=[]),patch('existing_ai.scan',side_effect=AssertionError('scan')):
            result=service.forget_disk('disk:'+str(self.disk))
        self.assertEqual([m['path'] for m in result['mounts']],[child['path']])
        self.assertEqual({n['id'] for n in result['nodes']},{'pc','disk:'+child['path']})
        self.assertEqual(result['edges'],[])
        self.assertEqual([r['mount']['path'] for r in result['records']],[child['path']])
        self.assertEqual(result['analysis']['findings'][0]['node'],'')
        self.assertEqual(result['move_undo'],'keep-journal')
        self.assertEqual(self.settings.read_text(),'{"model_folders":["keep"]}')
        self.assertEqual(sentinel.read_bytes(),b'model')
        self.assertEqual(cache.load(self.path)['mounts'],[child])

    def test_forget_rejects_present_or_unknown_disk_without_cache_change(self):
        disk={'id':'disk:'+str(self.disk),'kind':'disk','path':str(self.disk),'label':'Disk','detail':'','info':'','status':'missing','column':1}
        cache.save(self.path,facts([self.mount],[disk],True));before=self.path.read_bytes()
        with patch('existing_ai.mounts',return_value=[self.mount]):
            with self.assertRaises(ValueError):system.SystemMap(self.settings).forget_disk(disk['id'])
        with patch('existing_ai.mounts',return_value=[]):
            with self.assertRaises(ValueError):system.SystemMap(self.settings).forget_disk('disk:unknown')
        self.assertEqual(self.path.read_bytes(),before)

    def test_program_size_resolves_wrapper_and_hides_unattributable_script(self):
        build=self.disk/'runtime/build';build.mkdir(parents=True)
        binary=build/'server';binary.write_bytes(b'\x7fELFfixture');binary.chmod(0o755)
        current=build.parent/'current';current.symlink_to(build.name)
        wrapper=self.root/'wrapper';wrapper.write_text('#!/bin/sh\nexec '+str(current/'server')+' "$@"\n')
        self.assertEqual(system.program_place(str(wrapper)),build.parent)
        unknown=self.root/'unknown';unknown.write_text('#!/bin/sh\nexec server "$@"\n')
        self.assertIsNone(system.program_place(str(unknown)))
        row={'path':str(binary),'launch_path':str(current/'server'),'kind':'runtime','provider':'fixture','name':'Fixture','mount':self.mount}
        found=system.discovery_node(row)
        self.assertEqual(found['detail'],row['launch_path'])
        self.assertEqual(found['info'],str(binary))
        self.assertEqual(found['path'],str(binary))

    def test_default_map_uses_cache_but_undo_uses_durable_profile(self):
        import system_moves
        with patch('identity.cache_dir',return_value=self.root/'cache'), patch('ai_core.settings_file',return_value=self.settings):
            self.assertEqual(cache.location(),self.root/'cache/system-map.json')
            self.assertEqual(system_moves.journal_root(),self.settings.parent/'model-moves')

    def test_view_rejects_nonfinite_or_unknown_node(self):
        from flutter_backend import Service
        service=Service(self.settings)
        cache.save(self.path,facts())
        matrix=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
        for selected,transform in [('unknown',matrix),('pc',[float('nan')]*16)]:
            with self.assertRaises(ValueError):service.dispatch('system.view',{'selected':selected,'transform':transform})
        self.assertTrue(service.dispatch('system.view',{'selected':'pc','transform':matrix})['ok'])


if __name__=='__main__':unittest.main()
