"""Welcome selection validates completely and preserves unrelated saved choices."""
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import addons
import ai_core
import flutter_backend
import flutter_setup


class FlutterSetupTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / 'settings.json'
        self.items = [addons.Addon(Path('/fixture') / key, id=key, kind=kind, state=state)
                      for key, kind, state in [('one-agent', 'agent', 'verified'),
                          ('one-provider', 'provider', 'verified'), ('old-ui', 'feature', 'verified'),
                          ('bad-agent', 'agent', 'refused')]]
        self.registry = mock.Mock(items=self.items)
        def reload(enabled):
            for item in self.items:
                if item.state != 'refused':
                    item.state = 'loaded' if item.id in enabled else 'verified'
        self.registry.reload.side_effect = reload
        ai_core.update_settings(self.path, addons_enabled=['old-ui', 'missing-ui', 'one-provider'])

    def test_apply_is_explicit_and_preserves_unsupported_or_absent_addons(self):
        flutter_setup.apply(self.registry, self.path, ['one-agent'])
        saved = ai_core.load_settings(self.path)
        self.assertEqual(saved['addons_enabled'], ['missing-ui', 'old-ui', 'one-agent'])
        self.assertTrue(saved['setup_done'])
        self.assertEqual(self.items[1].state, 'verified')

    def test_rejects_entire_invalid_selection_before_loading_or_saving(self):
        before = self.path.read_bytes()
        for selected in (None, 'one-agent', ['one-agent', 'one-agent'], ['old-ui'], ['bad-agent'],
                         ['unknown'], [True], [f'item-{i}' for i in range(201)]):
            with self.subTest(selected=selected), self.assertRaises(ValueError):
                flutter_setup.apply(self.registry, self.path, selected)
        self.registry.reload.assert_not_called()
        self.assertEqual(self.path.read_bytes(), before)

    def test_load_failure_restores_runtime_and_keeps_settings_unchanged(self):
        before = self.path.read_bytes()
        self.registry.reload.side_effect = None
        with self.assertRaises(ValueError):
            flutter_setup.apply(self.registry, self.path, ['one-agent'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.registry.reload.call_args.args[0], {'old-ui', 'missing-ui', 'one-provider'})

    def test_write_failure_restores_previous_runtime_choices(self):
        before = self.path.read_bytes()
        with mock.patch.object(ai_core, 'update_settings', side_effect=OSError('fixture disk full')):
            with self.assertRaises(OSError):
                flutter_setup.apply(self.registry, self.path, ['one-agent'])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.items[0].state, 'verified')
        self.assertEqual(self.items[1].state, 'loaded')

    def test_later_marks_welcome_finished_without_enabling_or_loading_anything(self):
        service = flutter_backend.Service(self.path)
        service.adapters = self.registry
        service.dispatch('setup.later', {})
        self.assertTrue(ai_core.load_settings(self.path)['setup_done'])
        self.assertEqual(ai_core.load_settings(self.path)['addons_enabled'], ['old-ui', 'missing-ui', 'one-provider'])
        self.registry.reload.assert_not_called()

    def test_empty_selection_finishes_without_enabling_adapters(self):
        flutter_setup.apply(self.registry, self.path, [])
        self.assertTrue(ai_core.load_settings(self.path)['setup_done'])
        self.assertEqual(ai_core.load_settings(self.path)['addons_enabled'], ['missing-ui', 'old-ui'])

    def test_detection_uses_worker_without_reloading_main_service(self):
        service = flutter_backend.Service(self.path)
        service.adapters = self.registry
        with mock.patch.object(service.tasks, 'start_setup', return_value={'task': 'fixture'}) as start:
            self.assertEqual(service.dispatch('setup.detect', {}), {'task':'fixture'})
        start.assert_called_once_with(self.path)
        self.registry.reload.assert_not_called()

    def test_fresh_install_with_no_addons_still_gets_welcome(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[])
        with mock.patch('agents.list_agents', return_value=[]):
            self.assertTrue(service.snapshot()['setup_needed'])
            ai_core.update_settings(self.path, setup_done=True)
            self.assertFalse(service.snapshot()['setup_needed'])

    def test_protocol_rejects_extra_parameters_without_writing(self):
        service = flutter_backend.Service(self.path)
        service.adapters = self.registry
        before = self.path.read_bytes()
        for method, params in [('setup.apply', {'enabled': [], 'install':True}),
                               ('setup.detect', {'path':'/arbitrary'}), ('setup.later', {'enabled':[]})]:
            with self.assertRaises(ValueError):
                service.dispatch(method, params)
        self.assertEqual(self.path.read_bytes(), before)
