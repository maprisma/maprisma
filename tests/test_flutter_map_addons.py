"""Map add-on guards, signed metadata and reversible user-folder removal."""
import tempfile
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import addons
import ai_core
from flutter_addon_actions import Actions
from flutter_backend import Service


class MapAddonsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.user=self.root/'addons';self.user.mkdir()
        self.settings=self.root/'settings.json'
        self.settings.write_text('{"addons_enabled":["fixture","unrelated"]}')
        self.folder=self.user/'fixture';self.folder.mkdir();(self.folder/'addon.py').write_text('original bytes')
        self.item=addons.Addon(self.folder,id='fixture',name='Fixture',version='1',kind='agent',provides=['fixture'],state='loaded')
        def reload(enabled):self.item.state='loaded' if 'fixture' in enabled else 'verified'
        self.registry=SimpleNamespace(items=[self.item],reload=Mock(side_effect=reload),snapshot=lambda enabled:{'enabled':sorted(enabled)})
        self.actions=Actions()
        p=patch('addons.USER_DIR',self.user);p.start();self.addCleanup(p.stop)

    def test_removal_is_reviewed_and_undo_restores_original_files_and_state(self):
        plan=self.actions.preview(self.registry,'fixture')
        self.assertTrue(self.folder.exists())
        self.assertNotIn('path',plan)
        result=self.actions.apply(plan['preview'],self.registry,self.settings)
        self.assertFalse(self.folder.exists())
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['unrelated'])
        self.assertTrue(self.actions.undo(result['undo'],self.registry,self.settings)['ok'])
        self.assertEqual((self.folder/'addon.py').read_text(),'original bytes')
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['fixture','unrelated'])
        with self.assertRaises(ValueError):self.actions.undo(result['undo'],self.registry,self.settings)

    def test_undo_refuses_to_replace_new_addon(self):
        plan=self.actions.preview(self.registry,'fixture');result=self.actions.apply(plan['preview'],self.registry,self.settings)
        self.folder.mkdir();(self.folder/'new').write_text('keep')
        with self.assertRaises(ValueError):self.actions.undo(result['undo'],self.registry,self.settings)
        self.assertEqual((self.folder/'new').read_text(),'keep')

    def test_failed_settings_transaction_restores_folder(self):
        plan=self.actions.preview(self.registry,'fixture')
        with patch('ai_core.update_settings',side_effect=OSError('fixture')):
            with self.assertRaises(OSError):self.actions.apply(plan['preview'],self.registry,self.settings)
        self.assertEqual((self.folder/'addon.py').read_text(),'original bytes')
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['fixture','unrelated'])

    def test_bundled_and_changed_folders_are_refused(self):
        self.item.folder=self.root/'bundled'
        with self.assertRaises(ValueError):self.actions.preview(self.registry,'fixture')
        self.item.folder=self.folder
        plan=self.actions.preview(self.registry,'fixture')
        self.folder.rename(self.root/'old');self.folder.mkdir()
        with self.assertRaises(ValueError):self.actions.apply(plan['preview'],self.registry,self.settings)

    def test_switch_and_batch_and_removal_are_guarded_while_owned_agent_runs(self):
        service=Service(self.settings);service.adapters=self.registry
        service.sessions.items={'fixture':Mock()};service.sessions.poll=Mock(return_value=None)
        for method,params in [('addons.set_enabled',{'id':'fixture','enabled':False}),('setup.apply',{'enabled':[]}),('addons.remove_preview',{'id':'fixture'}),('addons.install',{'preview':'x'})]:
            with self.subTest(method=method),patch('provider_watch.agent_instances',return_value={}):
                with self.assertRaises(ValueError):service.dispatch(method,params)
        self.assertTrue(self.folder.exists());self.registry.reload.assert_not_called()

    def test_external_instances_do_not_block_addon_changes(self):
        service=Service(self.settings);service.adapters=self.registry
        with patch('provider_watch.agent_instances',return_value={'fixture':[['fixture']]}) as external:
            service.dispatch('addons.set_enabled',{'id':'fixture','enabled':False})
            external.assert_not_called()  # External processes are not adapter consumers owned by this service.
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['unrelated'])

    def test_installation_still_blocks_addon_changes(self):
        service=Service(self.settings);service.adapters=self.registry
        with patch.object(service,'addon_installing',return_value=True):
            with self.assertRaises(ValueError):service.dispatch('addons.set_enabled',{'id':'fixture','enabled':False})
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['fixture','unrelated'])

    def test_removal_preview_discloses_shared_gtk_folder_and_retention(self):
        plan=self.actions.preview(self.registry,'fixture')
        self.assertIn('This also removes it from Asterism (GTK).',plan['notes'])
        self.assertTrue(any('30 days' in note for note in plan['notes']))
        self.assertTrue(self.folder.exists())

    def test_retention_preserves_active_fresh_and_unrelated_backups_and_links(self):
        import os,time
        from flutter_addon_actions import prune_backups, BACKUP_RETENTION
        root=self.root/'addon-backups';root.mkdir(mode=0o700)
        expired=root/('a'*32);expired.mkdir();(expired/'addon.py').write_text('old')
        active=root/('b'*32);active.mkdir()
        fresh=root/('c'*32);fresh.mkdir()
        unrelated=root/'models';unrelated.mkdir();(unrelated/'keep').write_text('keep')
        linked=root/('d'*32);linked.symlink_to(unrelated,target_is_directory=True)
        future=time.time()+BACKUP_RETENTION+100
        os.utime(fresh,(future,future))
        prune_backups(root,keep=[active],now=future)
        self.assertFalse(expired.exists())
        self.assertTrue(active.is_dir());self.assertTrue(fresh.is_dir())
        self.assertEqual((unrelated/'keep').read_text(),'keep');self.assertTrue(linked.is_symlink())

    def test_cleanup_runs_only_after_successful_confirmed_removal(self):
        with patch('flutter_addon_actions.prune_backups') as prune:
            plan=self.actions.preview(self.registry,'fixture');prune.assert_not_called()
            result=self.actions.apply(plan['preview'],self.registry,self.settings)
            protected=prune.call_args.kwargs['keep']
            self.assertIn(self.root/'addon-backups'/result['undo'],protected)

    def test_immediate_switch_and_undo_restore_previous_choice(self):
        service=Service(self.settings)
        self.registry.snapshot=lambda enabled:{'enabled':sorted(enabled)}
        service.adapters=self.registry
        with patch('provider_watch.agent_instances',return_value={}):
            service.dispatch('addons.set_enabled',{'id':'fixture','enabled':False})
            self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['unrelated'])
            service.dispatch('addons.set_enabled',{'id':'fixture','enabled':True})
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['fixture','unrelated'])

    def test_failed_enable_does_not_change_saved_choice(self):
        service=Service(self.settings)
        self.settings.write_text('{"addons_enabled":["unrelated"]}')
        self.item.state='verified'
        self.registry.reload=Mock()  # Simulate a loader that could not activate the adapter.
        service.adapters=self.registry
        with patch('provider_watch.agent_instances',return_value={}):
            with self.assertRaises(ValueError):service.dispatch('addons.set_enabled',{'id':'fixture','enabled':True})
        self.assertEqual(ai_core.load_settings(self.settings)['addons_enabled'],['unrelated'])
        self.assertEqual(self.registry.reload.call_args.args[0],{'unrelated'})

    def test_online_signin_metadata_only_contains_matching_installed_agents(self):
        from flutter_addons import AdapterRegistry
        import providers
        registry=AdapterRegistry();registry.items=[addons.Addon(self.folder,id='online',kind='provider',provides=['cloud'])]
        agent=SimpleNamespace(command='fixture',name='Fixture',installed=True)
        provider=providers.Provider(key='cloud',name='Cloud',kind='online',agents=('fixture',))
        with patch('agents.list_agents',return_value=[agent]),patch('providers.get',return_value=provider),patch('harnesses.get',return_value=SimpleNamespace(access=lambda:None)):
            data=registry.snapshot(set())['addons'][0]
        self.assertEqual(data['sign_ins'],[{'command':'fixture','name':'Fixture'}])
        with patch('agents.list_agents',return_value=[]),patch('providers.get',return_value=provider):
            self.assertEqual(registry.snapshot(set())['addons'][0]['sign_ins'],[])

if __name__=='__main__':unittest.main()
