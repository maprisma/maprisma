"""Protocol framing and frontend-independent project actions; no desktop or agents started."""

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agent_projects
import agents
import ai_core
import flutter_backend


class FlutterBackendTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.project = self.root / "project with spaces; $literal"
        self.project.mkdir()
        self.settings = self.root / "settings.json"
        self.service = flutter_backend.Service(self.settings)
        self.catalog = [agents.Agent('test-agent', 'Test agent', '', installed=True),
                        agents.Agent('other-agent', 'Other agent', '')]
        patcher = mock.patch.object(agents, 'list_agents', return_value=self.catalog)
        patcher.start()
        self.addCleanup(patcher.stop)

    def request(self, value):
        source = io.BytesIO((json.dumps(value) + '\n').encode())
        output = io.StringIO()
        flutter_backend.serve(self.service, source, output)
        return json.loads(output.getvalue())

    def test_snapshot_uses_existing_agent_catalog_and_global_default_without_writes(self):
        ai_core.update_settings(self.settings, agent_folder=str(self.project))
        before = self.settings.read_bytes()
        result = self.service.snapshot()
        self.assertEqual(result['protocol'], 1)
        self.assertEqual(result['agents'][0]['command'], 'test-agent')
        self.assertEqual(result['projects']['test-agent']['default'], str(self.project))
        self.assertIsNone(result['projects']['test-agent']['pinned'])
        self.assertEqual(self.settings.read_bytes(), before)

    def test_pin_and_forget_are_per_agent_and_never_delete_folders(self):
        history = agent_projects.used('test-agent', str(self.project), {})
        ai_core.update_settings(self.settings, agent_project_history=history,
                                agent_projects={'other-agent': str(self.root)})
        self.service.dispatch('projects.pin', {'command': 'test-agent', 'path': str(self.project)})
        self.assertEqual(ai_core.load_settings(self.settings)['agent_projects']['test-agent'], str(self.project))
        self.service.dispatch('projects.forget', {'command': 'test-agent', 'path': str(self.project)})
        saved = ai_core.load_settings(self.settings)
        self.assertEqual(saved['agent_projects'], {'other-agent': str(self.root)})
        self.assertEqual(saved['agent_project_history']['test-agent'], [])
        self.assertTrue(self.project.is_dir())

    def test_unknown_agents_operations_and_bad_paths_do_not_write(self):
        for method, params in (
            ('shell.exec', {}),
            ('projects.pin', {'command': 'not-in-catalog', 'path': str(self.project)}),
            ('projects.pin', {'command': 'test-agent', 'path': 'relative'}),
            ('projects.pin', {'command': 'test-agent', 'path': {'bad': 'shape'}}),
            ('projects.pin', {'command': 'test-agent', 'path': None, 'extra': True}),
        ):
            with self.assertRaises(ValueError):
                self.service.dispatch(method, params)
        self.assertFalse(self.settings.exists())

    def test_protocol_rejects_malformed_or_mismatched_requests_and_recovers(self):
        for request in ([], {'id': True}, {'id': 3, 'protocol': 99},
                        {'id': 3, 'protocol': True},
                        {'id': 3, 'protocol': 1, 'method': 42},
                        {'id': 3, 'protocol': 1, 'method': 'app.snapshot', 'params': []}):
            self.assertIn('error', self.request(request))
        request = {'id': 7, 'protocol': 1, 'method': 'app.snapshot'}
        source = io.BytesIO(b'{invalid\n' + json.dumps(request).encode() + b'\n')
        output = io.StringIO()
        flutter_backend.serve(self.service, source, output)
        first, second = map(json.loads, output.getvalue().splitlines())
        self.assertIn('error', first)
        self.assertEqual(second['id'], 7)
        self.assertEqual(second['result']['protocol'], 1)

    def test_oversized_request_discards_tail_and_recovers(self):
        source = io.BytesIO(b'x' * (flutter_backend.MAX_REQUEST + 1) + b'\n{}\n')
        output = io.StringIO()
        flutter_backend.serve(self.service, source, output)
        responses = list(map(json.loads, output.getvalue().splitlines()))
        self.assertEqual(len(responses), 2)
        self.assertEqual(responses[0]['error']['code'], 'request_too_large')
        self.assertEqual(responses[1]['error']['code'], 'invalid_request')

    def test_internal_error_does_not_disclose_exception_text(self):
        with mock.patch.object(self.service, 'snapshot', side_effect=OSError('private-path-or-token')):
            response = self.request({'id': 1, 'protocol': 1, 'method': 'app.snapshot'})
        self.assertEqual(response, {'id': 1, 'error': {'code': 'operation_failed'}})

    def test_backend_import_has_no_gtk_dependency(self):
        import subprocess
        import sys
        result = subprocess.run([sys.executable, '-c',
            'import flutter_backend, sys; assert "gi.repository.Gtk" not in sys.modules'],
            cwd=Path(__file__).resolve().parent.parent, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_map_uses_the_existing_graph_contract_without_starting_any_agents(self):
        import agent_details
        import graph
        import inventory
        with mock.patch.object(agent_details, 'details_for', return_value=agent_details.Details()), \
                mock.patch.object(inventory, 'collect', return_value=inventory.Inventory()), \
                mock.patch.object(graph, 'LAST_MODEL', None):
            result = self.service.build_map()
        self.assertEqual([node['id'] for node in result['nodes']], ['agent:test-agent'])
        self.assertEqual(result['nodes'][0]['column'], 1)
        self.assertEqual(result['edges'], [])
        self.assertEqual(self.service.sessions.items, {})

    def test_service_validates_terminal_requests_before_touching_pty(self):
        for method, params in (
            ('sessions.read', {'session': 'not-owned'}),
            ('sessions.write', {'session': 'not-owned', 'data': 'aGVsbG8='}),
            ('sessions.stop', {'session': 999}),
            ('sessions.resize', {'session': 'not-owned', 'cols': 80, 'rows': 24}),
            ('sessions.start', {'command': 'test-agent', 'path': None, 'outside': 'yes'}),
        ):
            with self.assertRaises(ValueError):
                self.service.dispatch(method, params)

    def test_settings_update_validates_all_fields_before_any_write(self):
        ai_core.update_settings(self.settings, agent_projects={'test-agent': str(self.project)})
        original = self.settings.read_bytes()
        for values in ({'addons_enabled': ['unverified']}, {'language': 'unknown'},
                       {'map_layers': ['made-up-layer']}, {'agent_folder': 'relative'},
                       {'language': 'de', 'look': 'made-up-look'}):
            with self.assertRaises(ValueError):
                self.service.dispatch('settings.update', {'values': values})
            self.assertEqual(self.settings.read_bytes(), original)
        settings = self.service.dispatch('settings.update', {'values': {
            'language': 'de', 'agent_folder': str(self.project), 'map_layers': ['agents']}})
        self.assertEqual(settings['language'], 'de')
        self.assertEqual(settings['agent_folder'], str(self.project))
        self.assertEqual(ai_core.load_settings(self.settings)['agent_projects'], {'test-agent': str(self.project)})
        self.service.dispatch('settings.update', {'values': {'agent_folder': None}})
        self.assertIsNone(self.service.settings()['agent_folder'])

    def test_flutter_appearance_and_light_rate_defaults_persist_and_validate_atomically(self):
        self.assertEqual(self.service.settings()['flutter_theme_mode'], 'system')
        self.assertEqual(self.service.settings()['map_light_fps'], 20)
        for mode, fps in [('light', 30), ('dark', 60), ('system', 20)]:
            result = self.service.dispatch('settings.update', {'values': {
                'flutter_theme_mode': mode, 'map_light_fps': fps}})
            self.assertEqual(result['flutter_theme_mode'], mode)
            self.assertEqual(result['map_light_fps'], fps)
            self.assertEqual(ai_core.load_settings(self.settings)['map_light_fps'], fps)
        before = self.settings.read_bytes()
        for key, values in [('map_light_fps', [None, True, 20.0, '20', 0, 25, 120]),
                            ('flutter_theme_mode', [None, True, 'auto', 'omarchy', 'LIGHT', []])]:
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.service.dispatch('settings.update', {'values': {'language': 'de', key: value}})
                self.assertEqual(self.settings.read_bytes(), before)

    def test_details_are_explicit_metadata_and_datetime_fields_are_json_safe(self):
        import datetime
        import agent_details
        moment = datetime.datetime(2026, 10, 27, tzinfo=datetime.timezone.utc)
        info = agent_details.Details(plan='Team', model='example-model', today_tokens=42,
            last_used=moment, limits=[agent_details.Limit('Weekly', 0.4, moment)],
            providers=[agent_details.Provider('Example')])
        info.private_hook_data = 'must-not-cross-service-boundary'
        with mock.patch.object(agent_details, 'details_for', return_value=info):
            result = self.service.dispatch('agents.details', {'command': 'test-agent'})
        self.assertEqual(result['limits'][0]['resets_at'], moment.isoformat())
        self.assertEqual(result['last_used'], moment.isoformat())
        self.assertNotIn('must-not-cross-service-boundary', json.dumps(result))
        with self.assertRaises(ValueError):
            self.service.dispatch('agents.details', {'command': 'unknown-agent'})

    def test_map_layers_use_shared_graph_dependency_rules(self):
        import agent_details
        import graph
        import inventory
        self.service.dispatch('settings.update', {'values': {'map_layers': []}})
        with mock.patch.object(agent_details, 'details_for', return_value=agent_details.Details()), \
                mock.patch.object(inventory, 'collect', return_value=inventory.Inventory()), \
                mock.patch.object(graph, 'LAST_MODEL', None):
            result = self.service.build_map()
        self.assertEqual(result['nodes'], [])
        self.assertEqual(result['edges'], [])
        self.assertFalse(result['activity']['test-agent']['subagents_supported'])

    def test_start_uses_adapter_arguments_real_folder_and_clean_environment(self):
        from types import SimpleNamespace
        ai_core.update_settings(self.settings, agent_folder=str(self.project))
        with mock.patch('harnesses.get', return_value=SimpleNamespace(chat_app=False, start=('--fixed',))), \
                mock.patch('shutil.which', return_value='/fixture/program'), \
                mock.patch.object(self.service.sessions, 'start', return_value='session-one') as start, \
                mock.patch.dict('os.environ', {'CLAUDECODE': '1', 'CODEX_THREAD_ID': 'parent'}):
            result = self.service.dispatch('sessions.start', {'command': 'test-agent', 'path': None, 'outside': False})
        self.assertEqual(result['session'], 'session-one')
        command, argv, folder, env = start.call_args.args
        self.assertEqual((command, argv, folder), ('test-agent', ['/fixture/program', '--fixed'], str(self.project)))
        self.assertNotIn('CLAUDECODE', env)
        self.assertNotIn('CODEX_THREAD_ID', env)
        self.assertEqual(env['TERM'], 'xterm-256color')
        self.assertEqual(self.service.projects('test-agent')['history'], [{'path': str(self.project), 'available': True}])
        self.assertIsNone(self.service.projects('test-agent')['pinned'])

    def test_spawn_failure_does_not_record_history(self):
        from types import SimpleNamespace
        with mock.patch('harnesses.get', return_value=SimpleNamespace(chat_app=False, start=())), \
                mock.patch('shutil.which', return_value='/fixture/program'), \
                mock.patch.object(self.service.sessions, 'start', side_effect=OSError('failed')):
            with self.assertRaises(OSError):
                self.service.dispatch('sessions.start', {'command': 'test-agent', 'path': str(self.project), 'outside': False})
        self.assertFalse(self.settings.exists())

    def test_outside_launch_failure_does_not_record_history(self):
        from types import SimpleNamespace
        with mock.patch('harnesses.get', return_value=SimpleNamespace(chat_app=False, start=())), \
                mock.patch('shutil.which', return_value='/fixture/program'), \
                mock.patch('desktop.open_terminal', return_value=False):
            with self.assertRaises(OSError):
                self.service.dispatch('sessions.start', {'command': 'test-agent', 'path': str(self.project), 'outside': True})
        self.assertFalse(self.settings.exists())


    def test_slow_map_scan_returns_cached_result_without_blocking_service(self):
        self.service.tasks.items['scan'] = mock.Mock(state='done')
        with mock.patch.object(self.service.tasks, 'start_snapshot', return_value={'task': 'scan'}), \
             mock.patch.object(self.service.tasks, 'status', return_value={'state': 'running'}):
            self.assertEqual(self.service.dispatch('map.snapshot', {})['nodes'], [])
            self.assertEqual(self.service.dispatch('map.snapshot', {})['nodes'], [])
            self.assertEqual(self.service.dispatch('app.snapshot', {})['protocol'], 1)

    def test_subagent_history_settings_round_trip_and_reject_invalid_values(self):
        result = self.service.dispatch('settings.update', {'values': {'subagents_minutes': 60, 'subagents_kept': 20}})
        self.assertEqual(result['subagents_minutes'], 60)
        self.assertEqual(result['subagents_kept'], 20)
        before = self.settings.read_bytes()
        for key, value in [('subagents_minutes', True), ('subagents_minutes', 15),
                           ('subagents_kept', 0), ('subagents_kept', 100)]:
            with self.assertRaises(ValueError):
                self.service.dispatch('settings.update', {'values': {key: value}})
        self.assertEqual(self.settings.read_bytes(), before)

    def test_live_theme_is_lightweight_and_does_not_scan_catalog(self):
        with mock.patch.object(self.service, 'theme', return_value={'background':'#123456'}) as theme, \
                mock.patch.object(self.service, 'snapshot', side_effect=AssertionError('catalog scan')):
            self.assertEqual(self.service.dispatch('app.theme', {}), {'theme':{'background':'#123456'}})
        theme.assert_called_once()
        with self.assertRaises(ValueError):
            self.service.dispatch('app.theme', {'path':'/arbitrary'})

    def test_previews_build_their_own_map_when_dart_serves_map_snapshot(self):
        built = {'activity': {}, 'nodes': [{'id': 'agent:x'}], 'edges': []}
        with mock.patch.object(self.service, 'build_map', return_value=built) as build:
            self.assertIs(self.service.current_map(), built)
            self.assertIs(self.service.current_map(), built)      # reused within MAP_REUSE
        build.assert_called_once()
        self.service._map_built -= flutter_backend.MAP_REUSE + 1
        with mock.patch.object(self.service, 'build_map', return_value=built) as build:
            self.service.current_map()
        build.assert_called_once()
