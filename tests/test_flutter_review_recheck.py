"""Behavioral regressions from Claude's migration recheck."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from flutter_backend import Service


class RecheckTest(unittest.TestCase):
    def test_preview_changes_only_staged_identity(self):
        root = Path(__file__).resolve().parent.parent
        spec = importlib.util.spec_from_file_location('preview_build', root/'tools/build-flutter-preview.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original = (root/'flutter_app/linux/CMakeLists.txt').read_text()
        with tempfile.TemporaryDirectory() as directory:
            stage = Path(directory)
            (stage/'linux').mkdir()
            cmake = stage/'linux/CMakeLists.txt'
            cmake.write_text(original)
            module.preview_identity(stage)
            self.assertIn('set(APPLICATION_ID "io.github.ubruckhaus.Asterism.Devel")', cmake.read_text())
        self.assertEqual((root/'flutter_app/linux/CMakeLists.txt').read_text(), original)

    def test_idle_map_is_cached_but_settings_changes_trigger_scan(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = Path(directory)/'settings.json'
            settings.write_text('{}')
            service = Service(settings)
            with mock.patch.object(service.tasks, 'start_snapshot', return_value={'task':'scan'}) as start, \
                 mock.patch.object(service.tasks, 'status', return_value={'state':'done', 'result':{'nodes':[], 'edges':[]}}), \
                 mock.patch('flutter_backend.time.monotonic', return_value=100):
                service.dispatch('map.snapshot', {})
                # Simulate the queue's completed operation, avoiding a process fixture here.
                service.tasks.items['scan'] = mock.Mock(state='done')
                service.dispatch('map.snapshot', {})
                self.assertEqual(start.call_count, 1)
                settings.write_text('{"language":"de"}')
                service.dispatch('map.snapshot', {})
                self.assertEqual(start.call_count, 2)

    def test_manual_mode_still_allows_forced_refresh_and_poll_only_does_not_rescan(self):
        import ai_core
        with tempfile.TemporaryDirectory() as directory:
            service = Service(Path(directory)/'settings.json')
            ai_core.update_settings(service.settings_path, map_scan_interval=0)
            with mock.patch.object(service.tasks, 'start_snapshot', return_value={'task':'scan'}) as start, \
                 mock.patch.object(service.tasks, 'status', return_value={'state':'done','result':{'nodes':['fresh']}}):
                self.assertFalse(service.dispatch('map.snapshot', {})['pending'])
                start.assert_not_called()
                self.assertTrue(service.dispatch('map.snapshot', {'force':True})['pending'])
                service.tasks.items['scan'] = mock.Mock(state='done')
                result = service.dispatch('map.snapshot', {'poll':True})
                self.assertEqual(result['nodes'], ['fresh'])
                self.assertFalse(result['pending'])
                self.assertEqual(start.call_count, 1)
                self.assertTrue(start.call_args.kwargs['force'])

    def test_activity_target_does_not_repeat_details_or_inventory_scans(self):
        import agents, agent_details, inventory
        service = Service()
        catalog = [agents.Agent('fixture','Fixture','',installed=True)]
        with mock.patch.object(agents,'list_agents',return_value=catalog) as agent_scan, \
             mock.patch.object(agent_details,'details_for',return_value=agent_details.Details()) as details, \
             mock.patch.object(inventory,'collect',return_value=inventory.Inventory()) as collect, \
             mock.patch.object(service,'activity',return_value=({},{})) as activity:
            cache = {}
            service.build_map(cache)
            service.build_map(cache, ['activity'])
        self.assertEqual(agent_scan.call_count, 1)
        self.assertEqual(details.call_count, 1)
        self.assertEqual(collect.call_count, 1)
        self.assertEqual(activity.call_count, 2)

    def test_scan_settings_validate_atomically(self):
        import ai_core
        with tempfile.TemporaryDirectory() as directory:
            service = Service(Path(directory)/'settings.json')
            saved = service.dispatch('settings.update', {'values': {
                'map_scan_interval':30, 'map_scan_targets':['activity'], 'map_scan_pause_unfocused':True}})
            self.assertEqual(saved['map_scan_interval'], 30)
            before = service.settings_path.read_bytes()
            for values in ({'map_scan_interval':True}, {'map_scan_interval':6.0}, {'map_scan_interval':-1},
                           {'map_scan_targets':['arbitrary']}, {'map_scan_pause_unfocused':'yes'}):
                with self.assertRaises(ValueError):
                    service.dispatch('settings.update', {'values':values})
            self.assertEqual(service.settings_path.read_bytes(), before)

    def test_forced_refresh_waits_for_full_scan_after_inflight_partial_scan(self):
        import ai_core
        with tempfile.TemporaryDirectory() as directory:
            service = Service(Path(directory)/'settings.json')
            ai_core.update_settings(service.settings_path, map_scan_targets=['activity'])
            service.tasks.items = {'partial':mock.Mock(), 'full':mock.Mock()}
            statuses = [
                {'state':'running'},
                {'state':'done','result':{'nodes':['partial-data']}},
                {'state':'running'},
                {'state':'done','result':{'nodes':['full-data']}},
            ]
            with mock.patch.object(service.tasks,'poll'), \
                 mock.patch.object(service.tasks,'status',side_effect=statuses), \
                 mock.patch.object(service.tasks,'start_snapshot',side_effect=[{'task':'partial'},{'task':'full'}]) as start:
                service.dispatch('map.snapshot', {})
                # Even switching to manual-only must not drop the requested full refresh.
                ai_core.update_settings(service.settings_path, map_scan_interval=0)
                self.assertTrue(service.dispatch('map.snapshot', {'force':True})['pending'])
                self.assertEqual(start.call_count, 1)
                next_result = service.dispatch('map.snapshot', {'poll':True})
                self.assertTrue(next_result['pending'])
                self.assertEqual(next_result['nodes'], ['partial-data'])
                self.assertEqual([call.kwargs['force'] for call in start.call_args_list], [False,True])
                self.assertTrue(service.dispatch('map.snapshot', {'poll':True})['pending'])
                final = service.dispatch('map.snapshot', {'poll':True})
                self.assertFalse(final['pending'])
                self.assertEqual(final['nodes'], ['full-data'])
                self.assertEqual(start.call_count, 2)

    def test_unrelated_settings_writes_do_not_bypass_scan_interval(self):
        import ai_core
        with tempfile.TemporaryDirectory() as directory:
            service = Service(Path(directory)/'settings.json')
            ai_core.update_settings(service.settings_path, map_scan_interval=30)
            service.tasks.items['scan'] = mock.Mock()
            with mock.patch.object(service.tasks,'poll'), \
                 mock.patch.object(service.tasks,'status',return_value={'state':'done','result':{'nodes':[]}}), \
                 mock.patch.object(service.tasks,'start_snapshot',return_value={'task':'scan'}) as start, \
                 mock.patch('flutter_backend.time.monotonic',return_value=100) as clock:
                service.dispatch('map.snapshot', {})
                for i in range(3):
                    ai_core.update_settings(service.settings_path,
                        agent_project_history={'fixture':[f'/project/{i}']}, setup_done=bool(i))
                    service.dispatch('map.snapshot', {})
                self.assertEqual(start.call_count, 1)
                clock.return_value = 130
                service.dispatch('map.snapshot', {})
                self.assertEqual(start.call_count, 2)
