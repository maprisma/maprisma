import contextlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import addons
import ai_core
import flutter_addons
import flutter_backend
import harnesses
import providers


class FlutterAddonsTest(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        for registry in (harnesses, providers):
            for method in ('remove_added', 'hide_built_in', 'changed'):
                self.stack.enter_context(mock.patch.object(registry, method))

    def test_only_verified_enabled_service_adapters_execute(self):
        items = [addons.Addon(Path('/fixture') / name, id=name, kind=kind, state=state, provides=[name])
                 for name, kind, state in (
                     ('one-agent', 'agent', 'verified'), ('one-provider', 'provider', 'verified'),
                     ('off-agent', 'agent', 'verified'), ('bad-agent', 'agent', 'refused'),
                     ('ui-feature', 'feature', 'verified'), ('ui-extension', 'extension', 'verified'))]
        with mock.patch.object(addons, 'find', return_value=[a.folder for a in items]), \
                mock.patch.object(addons, 'verify', side_effect=items), \
                mock.patch.object(addons, 'load') as load:
            registry = flutter_addons.AdapterRegistry()
            enabled = {a.id for a in items} - {'off-agent'}
            registry.reload(enabled)
        self.assertEqual([call.args[0].id for call in load.call_args_list], ['one-agent', 'one-provider'])
        self.assertIn('ui-feature', enabled)
        self.assertIn('ui-extension', enabled)
        harnesses.hide_built_in.assert_called_once_with({'one-agent', 'off-agent'})
        snapshot = registry.snapshot(enabled)
        self.assertFalse(next(a for a in snapshot['addons'] if a['id'] == 'ui-feature')['supported'])

    def test_startup_migrates_before_loading_adapters(self):
        import config_migration
        with tempfile.TemporaryDirectory() as directory:
            service = flutter_backend.Service(Path(directory) / 'settings.json')
            events = []
            registry = mock.Mock()
            registry.reload.side_effect = lambda _: events.append('reload')
            with mock.patch.object(config_migration, 'migrate', side_effect=lambda **_: events.append('migration')), \
                    mock.patch.object(ai_core, 'migrate_settings', side_effect=lambda _: events.append('settings')), \
                    mock.patch.object(flutter_addons, 'AdapterRegistry', return_value=registry), \
                    mock.patch.object(service, 'finish_plugin_migration', side_effect=lambda: events.append('activation')):
                service.initialize()
            self.assertEqual(events, ['migration', 'settings', 'reload', 'activation'])

    def test_detection_restores_enabled_adapters_even_when_a_reader_fails(self):
        import agents
        import inventory
        registry = flutter_addons.AdapterRegistry()
        item = addons.Addon(Path('/fixture'), id='one-agent', kind='agent',
                            state='verified', provides=['test-agent'])
        registry.items = [item]
        def reload(enabled):
            item.state = 'loaded' if item.id in enabled else 'verified'
        with mock.patch.object(registry, 'reload', side_effect=reload) as load, \
                mock.patch.object(inventory, 'own_processes', return_value=[]), \
                mock.patch.object(agents, 'detect', side_effect=OSError('fixture')):
            with self.assertRaises(OSError):
                registry.installed({'old-ui-feature'})
        self.assertEqual(load.call_args_list, [mock.call({'old-ui-feature', 'one-agent'}),
                                               mock.call({'old-ui-feature'})])

    def test_refused_or_ui_addons_cannot_be_enabled_through_the_service(self):
        with tempfile.TemporaryDirectory() as directory:
            service = flutter_backend.Service(Path(directory) / 'settings.json')
            service.adapters = mock.Mock(items=[
                addons.Addon(Path('/fixture'), id='bad-agent', kind='agent', state='refused'),
                addons.Addon(Path('/fixture'), id='ui-feature', kind='feature', state='verified')])
            for aid in ('bad-agent', 'ui-feature', 'unknown-agent'):
                with self.assertRaises(ValueError):
                    service.dispatch('addons.set_enabled', {'id': aid, 'enabled': True})
            self.assertFalse(service.settings_path.exists())

    def test_pending_legacy_activation_unions_enabled_choices_and_marks_only_after_detection(self):
        with tempfile.TemporaryDirectory() as directory:
            service = flutter_backend.Service(Path(directory) / 'settings.json')
            ai_core.update_settings(service.settings_path, addons_enabled=['old-ui-feature'],
                                    plugin_migration={'addons_pending': True, 'backup': 'existing-backup'})
            service.adapters = mock.Mock(items=[addons.Addon(Path('/fixture'), id='one-agent',
                                                            kind='agent', state='verified')])
            service.adapters.installed.return_value = {'one-agent'}
            service.finish_plugin_migration()
            saved = ai_core.load_settings(service.settings_path)
            self.assertEqual(saved['addons_enabled'], ['old-ui-feature', 'one-agent'])
            self.assertFalse(saved['plugin_migration']['addons_pending'])
            self.assertEqual(saved['plugin_migration']['backup'], 'existing-backup')

    def test_failed_detection_keeps_migration_pending_without_settings_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            service = flutter_backend.Service(Path(directory) / 'settings.json')
            ai_core.update_settings(service.settings_path, plugin_migration={'addons_pending': True})
            before = service.settings_path.read_bytes()
            service.adapters = mock.Mock(items=[addons.Addon(Path('/fixture'), id='one-agent',
                                                            kind='agent', state='verified')])
            service.adapters.installed.side_effect = OSError('fixture failure')
            service.finish_plugin_migration()
            self.assertEqual(service.settings_path.read_bytes(), before)
