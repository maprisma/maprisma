import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from contextlib import nullcontext

import connect
import inventory
import system_moves as moves


class MoveTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'models';self.source.mkdir()
        for name in ('one.gguf','two.gguf'):(self.source/name).write_bytes(b'original '+name.encode())
        self.disk=self.root/'disk';self.disk.mkdir()
        self.mount={'path':str(self.disk),'filesystem':'ext4','identity':'x'}
        self.settings=self.root/'settings.json';self.settings.write_text('{"language":"de","private":"keep"}')
        self.ini=self.root/'models.ini';self.ini.write_text('[one]\nmodel = '+str(self.source/'one.gguf')+'\n')
        for name,kwargs in (
            ('existing_ai.mounts',{'return_value':[self.mount]}),('providers.built_in_local',{'return_value':[]}),
            ('providers.local',{'return_value':[]}),('model_folders.MODELS_INI',{'new':self.ini}),
            ('flutter_addon_catalog.install_lock',{'side_effect':nullcontext}),
        ):
            item=patch(name,**kwargs);item.start();self.addCleanup(item.stop)
        self.selection={'source':str(self.source),'disk':str(self.disk),'mount':self.mount,'settings_path':str(self.settings)}

    def test_preview_is_read_only_and_public_result_hides_config_values(self):
        before=self.settings.read_text()
        record=moves.prepare(self.selection)
        public=moves.Moves().register(record)
        self.assertNotIn('keep',json.dumps(public))
        self.assertEqual(self.settings.read_text(),before)
        self.assertEqual(list(self.disk.iterdir()),[])
        self.assertEqual(public['count'],2)

    def test_default_profile_undo_survives_cache_clean(self):
        cache=self.root/'cache';cache.mkdir()
        with patch('ai_core.settings_file',return_value=self.settings), patch('identity.cache_dir',return_value=cache):
            record=moves.prepare({**self.selection,'settings_path':None})
            result=moves.execute(json.dumps(record).encode())
            journal=self.settings.parent/'model-moves'/result['move_undo']/'journal.json'
            self.assertTrue(journal.is_file())
            import shutil
            shutil.rmtree(cache)
            self.assertTrue(moves.undo(result['move_undo'])['ok'])
        self.assertEqual((self.source/'one.gguf').read_bytes(),b'original one.gguf')

    def test_legacy_default_cache_journal_remains_readable(self):
        cache=self.root/'cache'
        with patch('ai_core.settings_file',return_value=self.settings), patch('identity.cache_dir',return_value=cache):
            record=moves.prepare({**self.selection,'settings_path':None})
            with patch('system_moves.journal_root',return_value=cache/'model-moves'):
                result=moves.execute(json.dumps(record).encode())
            self.assertTrue(moves.undo(result['move_undo'])['ok'])
        self.assertEqual((self.source/'one.gguf').read_bytes(),b'original one.gguf')

    def test_move_and_persistent_undo_preserve_files_and_configuration(self):
        before=self.settings.read_text();old_ini=self.ini.read_text()
        record=moves.prepare(self.selection)
        result=moves.execute(json.dumps(record).encode())
        self.assertTrue(result['ok'])
        self.assertFalse((self.source/'one.gguf').exists())
        self.assertEqual((self.disk/'models/one.gguf').read_bytes(),b'original one.gguf')
        self.assertIn(str(self.disk/'models'),self.ini.read_text())
        self.assertEqual(json.loads(self.settings.read_text())['private'],'keep')
        # A new service instance can use the journal; the old in-memory plan is unnecessary.
        undone=moves.undo(result['move_undo'],self.settings)
        self.assertTrue(undone['ok'])
        self.assertEqual((self.source/'one.gguf').read_bytes(),b'original one.gguf')
        self.assertEqual(self.settings.read_text(),before)
        self.assertEqual(self.ini.read_text(),old_ini)

    def test_copy_then_remove_and_undo_follow_existing_cross_disk_path(self):
        with patch('model_folders._same_disk',return_value=False):
            record=moves.prepare(self.selection)
            self.assertTrue(record['facts']['move']['copy'])
            result=moves.execute(json.dumps(record).encode())
        self.assertTrue(result['ok'])
        self.assertTrue(moves.undo(result['move_undo'],self.settings)['ok'])
        self.assertEqual((self.source/'two.gguf').read_bytes(),b'original two.gguf')

    def test_stale_source_or_settings_cannot_be_applied(self):
        record=moves.prepare(self.selection)
        self.settings.write_text('{"new":"value"}')
        with self.assertRaises(ValueError):moves.execute(json.dumps(record).encode())
        self.assertTrue((self.source/'one.gguf').is_file())
        self.assertEqual(list(self.disk.iterdir()),[])

    def test_partial_failure_rolls_back_already_moved_files(self):
        record=moves.prepare(self.selection)
        import model_move
        original=model_move.apply;calls=[]
        def fail_second(move,**kwargs):
            calls.append(move)
            if len(calls)==2:raise OSError('fixture')
            return original(move,**kwargs)
        with patch('model_move.apply',side_effect=fail_second):result=moves.execute(json.dumps(record).encode())
        self.assertFalse(result['ok'])
        self.assertIsNone(result['move_undo'])
        self.assertTrue((self.source/'one.gguf').is_file())
        self.assertTrue((self.source/'two.gguf').is_file())

    def test_undo_will_not_overwrite_a_new_file_at_the_old_path(self):
        record=moves.prepare(self.selection);result=moves.execute(json.dumps(record).encode())
        (self.source/'one.gguf').write_bytes(b'new user file')
        undone=moves.undo(result['move_undo'],self.settings)
        self.assertFalse(undone['ok'])
        self.assertEqual((self.source/'one.gguf').read_bytes(),b'new user file')
        self.assertTrue((self.disk/'models/one.gguf').is_file())

    def test_relative_model_links_are_repaired_and_restored(self):
        router=self.root/'router';router.mkdir()
        link=router/'one.gguf';link.symlink_to('../models/one.gguf')
        rt=inventory.Runtime('fixture','Fixture',installed=True,models_dir=str(router))
        provider=SimpleNamespace(key='fixture',detect=lambda processes:rt,model_folder_changes=None)
        with patch('providers.built_in_local',return_value=[provider]),patch('model_folders.reads_gguf',return_value=True):
            record=moves.prepare(self.selection);result=moves.execute(json.dumps(record).encode())
        self.assertEqual(link.resolve(),self.disk/'models/one.gguf')
        self.assertTrue(moves.undo(result['move_undo'],self.settings)['ok'])
        self.assertEqual(link.readlink(),Path('../models/one.gguf'))

    def test_running_reader_prevents_any_move(self):
        rt=inventory.Runtime('fixture','Fixture',installed=True,running=True,models_dir=str(self.source))
        provider=SimpleNamespace(key='fixture',detect=lambda processes:rt,model_folder_changes=None)
        with patch('providers.built_in_local',return_value=[provider]),patch('model_folders.reads_gguf',return_value=True):
            with self.assertRaises(ValueError):moves.prepare(self.selection)
        self.assertEqual(list(self.disk.iterdir()),[])

    def test_bad_undo_handle_cannot_name_a_file(self):
        for token in ('../settings.json','/tmp/path',None):
            with self.assertRaises(ValueError):moves.undo(token,self.settings)


if __name__=='__main__':unittest.main()
