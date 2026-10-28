import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import flutter_providers as api
import inventory
import models_ctl


class FlutterProvidersTest(unittest.TestCase):
    def setUp(self):
        self.rt = inventory.Runtime('fixture', 'Fixture runtime', installed=True, running=True,
                                    models_dir='/fixture/models', models=['example-model'])
        self.engine = mock.Mock(download='file', can_load=True)
        self.patches = [mock.patch.object(api, 'runtime', return_value=self.rt),
                        mock.patch.object(api.llm_engine, 'of', return_value=self.engine)]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_client_cannot_supply_commands_urls_destinations_or_split_paths(self):
        for operation, params in (
            ('shell.exec', {'argv': ['sh']}),
            ('runtime.start', {'key': 'fixture', 'argv': ['sh']}),
            ('models.files', {'repo': 'https://evil.test/repo'}),
            ('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': '../escape.gguf', 'size': 1}),
            ('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': '/escape.gguf', 'size': 1}),
            ('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': 'model.gguf', 'into': '/tmp'}),
            ('model.load', {'key': 'fixture', 'model': '--option'}),
            ('models.search', {'query': ''}),
        ):
            with self.assertRaises(ValueError):
                api.validate(operation, params)

    def test_load_uses_registered_runtime_and_known_model(self):
        with mock.patch.object(api.runtime_ctl, 'load', return_value=(True, '')) as load:
            self.assertEqual(api.execute('model.load', {'key': 'fixture', 'model': 'example-model'}), {'ok': True})
            load.assert_called_once_with(self.rt, 'example-model')
            with self.assertRaises(ValueError):
                api.execute('model.load', {'key': 'fixture', 'model': 'unknown-model'})

    def test_stop_requires_controllable_installed_provider_and_propagates_failure(self):
        with mock.patch.object(api.runtime_ctl, 'can_control', return_value=False), \
                mock.patch.object(api.runtime_ctl, 'stop') as stop:
            with self.assertRaises(ValueError):
                api.execute('runtime.stop', {'key': 'fixture'})
            stop.assert_not_called()
        with mock.patch.object(api.runtime_ctl, 'can_control', return_value=True), \
                mock.patch.object(api.runtime_ctl, 'stop', return_value=(False, 'private diagnostic')):
            with self.assertRaisesRegex(RuntimeError, '^Provider operation failed$'):
                api.execute('runtime.stop', {'key': 'fixture'})

    def test_download_resolves_metadata_and_destination_in_the_backend(self):
        entry = models_ctl.GgufFile('model.gguf', ['part-one.gguf', 'part-two.gguf'], 100)
        progress = mock.Mock()
        with mock.patch.object(models_ctl, 'files', return_value=[entry]) as files, \
                mock.patch.object(models_ctl, 'download_gguf') as download:
            api.execute('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': 'model.gguf', 'size': 100}, progress)
        files.assert_called_once_with('owner/repo')
        self.assertEqual(download.call_args.args[:5], ('fixture', Path('/fixture/models'), 'owner/repo', entry, progress))
        self.engine.refresh.assert_called_once_with(self.rt)

    def test_missing_download_entry_never_starts_download(self):
        with mock.patch.object(models_ctl, 'files', return_value=[]), \
                mock.patch.object(models_ctl, 'download_gguf') as download:
            with self.assertRaises(ValueError):
                api.execute('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': 'gone.gguf', 'size': 100})
            download.assert_not_called()

    def test_changed_download_size_requires_a_fresh_selection(self):
        entry = models_ctl.GgufFile('model.gguf', ['model.gguf'], 200)
        with mock.patch.object(models_ctl, 'files', return_value=[entry]), \
                mock.patch.object(models_ctl, 'download_gguf') as download:
            with self.assertRaisesRegex(ValueError, 'metadata changed'):
                api.execute('models.download', {'key': 'fixture', 'repo': 'owner/repo', 'file': 'model.gguf', 'size': 100})
            download.assert_not_called()

    def test_import_rejects_relative_missing_and_non_gguf_targets(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / 'ordinary.json'
            file.touch()
            link = Path(directory) / 'model.gguf'
            link.symlink_to(file)
            for path in ('relative.gguf', str(file), str(link), str(Path(directory) / 'missing.gguf')):
                with self.assertRaises((ValueError, OSError)):
                    api.execute('model.import', {'key': 'fixture', 'path': path})
            self.engine.add_file.assert_not_called()

    def test_readonly_snapshot_exports_only_runtime_metadata(self):
        provider = SimpleNamespace(key='fixture', name='Fixture', kind='local', detect=lambda _: self.rt)
        with mock.patch.object(api.providers, 'local', return_value=[provider]), \
                mock.patch.object(api.providers, 'online', return_value=[]), \
                mock.patch.object(api.inventory, 'own_processes', return_value=[]), \
                mock.patch.object(api.runtime_ctl, 'can_control', return_value=True):
            result = api.snapshot()
        self.assertEqual(result['local'][0]['models'], ['example-model'])
        self.assertNotIn('service', result['local'][0])
        self.assertNotIn('env', result['local'][0])
