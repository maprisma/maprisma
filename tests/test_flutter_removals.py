import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import flutter_removals as api
import inventory


class ModelRemovalTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.models = self.root / 'models'
        self.models.mkdir()
        self.file = self.models / 'model.gguf'
        self.file.write_bytes(b'fixture model')
        self.rt = inventory.Runtime('fixture', 'Fixture provider', installed=True,
                                     models_dir=str(self.models), models=['model'])
        self.engine = mock.Mock(removable='file', gguf_layout='flat')
        for patcher in (mock.patch.object(api.flutter_providers, 'runtime', return_value=self.rt),
                        mock.patch.object(api.llm_engine, 'of', return_value=self.engine),
                        mock.patch.object(api.providers, 'local', return_value=[]),
                        mock.patch.object(api.inventory, 'own_processes', return_value=[])):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_preview_has_exact_files_without_deleting_or_accepting_client_paths(self):
        controller = api.Removals()
        result = controller.preview({'key': 'fixture', 'model': 'model'})
        self.assertEqual(result['files'], [str(self.file)])
        self.assertEqual(result['provider'], 'Fixture provider')
        self.assertEqual(result['mode'], 'file')
        self.assertTrue(self.file.exists())
        with self.assertRaises(ValueError):
            controller.preview({'key': 'fixture', 'model': 'model', 'paths': ['/arbitrary']})
        with self.assertRaises(ValueError):
            controller.preview({'key': 'fixture', 'model': 'not-in-catalog'})

    def test_file_replaced_since_preview_is_not_trashed(self):
        snapshot = api.record('fixture', 'model')
        self.file.unlink()
        self.file.write_bytes(b'a changed model')
        with mock.patch.object(api.models_ctl, 'trash') as trash:
            with self.assertRaises(ValueError):
                api.execute(snapshot)
            trash.assert_not_called()
        self.assertEqual(self.file.read_bytes(), b'a changed model')

    def test_parent_directory_replacement_is_detected(self):
        snapshot = api.record('fixture', 'model')
        self.models.rename(self.root / 'old-models')
        self.models.mkdir()
        self.file.write_bytes(b'replacement')
        with mock.patch.object(api.models_ctl, 'trash') as trash:
            with self.assertRaises(ValueError):
                api.execute(snapshot)
            trash.assert_not_called()

    def test_new_shared_reference_requires_another_preview(self):
        snapshot = api.record('fixture', 'model')
        other_dir = self.root / 'other-models'
        other_dir.mkdir()
        (other_dir / 'shared.gguf').symlink_to(self.file)
        provider = SimpleNamespace(key='other', detect=lambda _: inventory.Runtime(
            'other', 'Other provider', models_dir=str(other_dir)))
        with mock.patch.object(api.providers, 'local', return_value=[provider]), \
                mock.patch.object(api.models_ctl, 'trash') as trash:
            with self.assertRaises(ValueError):
                api.execute(snapshot)
            trash.assert_not_called()

    def test_link_removal_does_not_target_original_model_data(self):
        self.file.unlink()
        original = self.root / 'original.gguf'
        original.write_bytes(b'original data')
        self.file.symlink_to(original)
        snapshot = api.record('fixture', 'model')
        self.assertTrue(snapshot['links_only'])
        with mock.patch.object(api.models_ctl, 'trash') as trash:
            result = api.execute(snapshot)
        trash.assert_called_once_with([self.file])
        self.assertTrue(result['recoverable'])
        self.assertEqual(original.read_bytes(), b'original data')

    def test_api_removal_uses_validated_runtime_and_is_explicitly_not_recoverable(self):
        self.engine.removable = 'api'
        snapshot = api.record('fixture', 'model')
        with mock.patch.object(api.models_ctl, 'trash') as trash:
            result = api.execute(snapshot)
        self.engine.remove.assert_called_once_with(self.rt, 'model')
        trash.assert_not_called()
        self.assertFalse(result['recoverable'])

    def test_removal_handles_expire_and_cannot_be_replayed(self):
        controller = api.Removals()
        queued = mock.Mock(return_value={'task': 'queued'})
        preview = controller.preview({'key': 'fixture', 'model': 'model'})
        controller.apply(preview['removal'], queued)
        queued.assert_called_once()
        with self.assertRaises(ValueError):
            controller.apply(preview['removal'], queued)
        with mock.patch.object(api.time, 'monotonic', return_value=0):
            preview = controller.preview({'key': 'fixture', 'model': 'model'})
        with mock.patch.object(api.time, 'monotonic', return_value=301):
            with self.assertRaises(ValueError):
                controller.apply(preview['removal'], queued)
        self.assertEqual(queued.call_count, 1)
