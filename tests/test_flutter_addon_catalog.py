"""Signed catalog handoff, stale previews and commit protection; no live downloads."""
from dataclasses import asdict, replace
import json
from pathlib import Path
import tempfile
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest import mock

import addon_store
import addons
import ai_core
import flutter_addon_catalog as api
import flutter_backend
from flutter_tasks import Tasks, Task


class FlutterAddonCatalogTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / 'settings.json'
        self.enterContext(mock.patch.object(addons, 'USER_DIR', Path(temp.name) / 'addons'))
        ai_core.update_settings(self.path, addons_online=True, addons_enabled=['saved-ui'])
        self.entry = addon_store.Entry('test-adapter', 'Test adapter', '2.0.0', kind='agent',
            summary='Summary', description='Description', reads=['metadata'], sends=['nothing'],
            capabilities=['agent'], url=addon_store.DOWNLOADS + 'test-adapter-2.0.0/test-adapter-2.0.0.zip',
            size=5, sha256='0' * 64, commands=['program'], paths=['~/private-location'])
        self.record = {'entry':asdict(self.entry), 'installed_version':''}
        self.catalog = api.Catalog()

    def body(self, record=None):
        return json.dumps({'record':self.record if record is None else record,
                           'settings_path':str(self.path)}).encode()

    def test_public_catalog_contains_review_disclosures_but_not_transport_or_detection_fields(self):
        result = self.catalog.register({'records':[self.record], 'online':True})
        entry = result['entries'][0]
        self.assertEqual(entry['reads'], ['metadata'])
        self.assertEqual(entry['capabilities'], ['agent'])
        self.assertEqual(entry['action'], 'install')
        serialized = json.dumps(result)
        for private in ('https://', 'sha256', 'private-location', 'commands', 'url'):
            self.assertNotIn(private, serialized)
        self.assertIn(entry['preview'], self.catalog.previews)

    def test_present_says_only_whether_the_program_is_on_this_pc(self):
        for found in (False, True):
            with mock.patch.object(addon_store.shutil, 'which', return_value='/x/program' if found else None):
                item = self.catalog.register({'records':[self.record], 'online':True})['entries'][0]
            self.assertIs(item['present'], found)

    def test_feature_addons_have_no_install_handle(self):
        self.record['entry']['kind'] = 'feature'
        item = self.catalog.register({'records':[self.record], 'online':True})['entries'][0]
        self.assertFalse(item['supported'])
        self.assertIsNone(item['preview'])

    def test_update_action_requires_a_newer_catalog_version(self):
        for old, expected in [('1.0.0','update'), ('2.0.0',''), ('3.0.0','')]:
            with self.subTest(old=old):
                self.record['installed_version'] = old
                item = self.catalog.register({'records':[self.record], 'online':True})['entries'][0]
                self.assertEqual(item['action'], expected)
                self.assertEqual(item['preview'] is None, expected == '')

    def test_queue_rejection_preserves_preview_and_success_consumes_it(self):
        token = self.catalog.register({'records':[self.record], 'online':True})['entries'][0]['preview']
        with self.assertRaises(ValueError):
            self.catalog.apply(token, mock.Mock(side_effect=ValueError('queue full')))
        self.assertIn(token, self.catalog.previews)
        self.assertEqual(self.catalog.apply(token, lambda record: {'task':'owned'}), {'task':'owned'})
        with self.assertRaises(ValueError):
            self.catalog.apply(token, lambda _: self.fail('replayed'))

    def test_expired_previews_do_not_spawn_workers(self):
        with mock.patch.object(api.time, 'monotonic', return_value=1):
            token = self.catalog.register({'records':[self.record], 'online':True})['entries'][0]['preview']
        with mock.patch.object(api.time, 'monotonic', return_value=602):
            with self.assertRaises(ValueError):
                self.catalog.apply(token, lambda _: self.fail('expired'))

    def test_offline_catalog_uses_existing_signed_cache_policy(self):
        ai_core.update_settings(self.path, addons_online=False)
        with mock.patch.object(addon_store, 'catalog', return_value=[self.entry]) as catalog, \
             mock.patch.object(api, 'installed', return_value={}):
            result = api.catalog_records(self.path)
        catalog.assert_called_once_with(online=False)
        self.assertFalse(result['online'])

    def test_install_rechecks_online_preference(self):
        ai_core.update_settings(self.path, addons_online=False)
        with mock.patch.object(addon_store, 'install') as install:
            with self.assertRaises(ValueError):
                api.execute(self.body())
        install.assert_not_called()

    def test_changed_catalog_entry_or_disclosures_require_new_review(self):
        for field, value in [('sha256','1'*64), ('reads',['new data']), ('sends',['remote data']), ('version','3.0.0')]:
            with self.subTest(field=field), mock.patch.object(addon_store, 'catalog', return_value=[replace(self.entry, **{field:value})]), \
                 mock.patch.object(addon_store, 'install') as install:
                with self.assertRaises(ValueError):
                    api.execute(self.body())
                install.assert_not_called()

    def test_install_detects_changed_existing_version(self):
        item = addons.Addon(Path('/fixture'), id=self.entry.id, version='1.0.0', state='verified')
        with mock.patch.object(addon_store, 'catalog', return_value=[self.entry]), \
             mock.patch.object(api, 'installed', return_value={self.entry.id:item}), \
             mock.patch.object(addon_store, 'install') as install:
            with self.assertRaises(ValueError):
                api.execute(self.body())
        install.assert_not_called()

    def test_worker_install_leaves_enabled_choices_unchanged(self):
        before = self.path.read_bytes()
        item = addons.Addon(Path('/fixture'), id=self.entry.id, version=self.entry.version, state='verified')
        with mock.patch.object(addon_store, 'catalog', return_value=[self.entry]), \
             mock.patch.object(api, 'installed', return_value={}), \
             mock.patch.object(addon_store, 'install', return_value=item) as install:
            result = api.execute(self.body())
        install.assert_called_once_with(self.entry)
        self.assertEqual(result, {'ok':True, 'id':self.entry.id, 'version':self.entry.version})
        self.assertEqual(self.path.read_bytes(), before)

    def test_wrong_archive_hash_is_rejected_by_existing_installer_before_file_install(self):
        with mock.patch.object(addon_store, 'catalog', return_value=[self.entry]), \
             mock.patch.object(api, 'installed', return_value={}), \
             mock.patch('netfetch.fetch', return_value=b'wrong'), \
             mock.patch.object(addon_store, 'install_bytes') as install_bytes:
            with self.assertRaises(addon_store.InstallError):
                api.execute(self.body())
        install_bytes.assert_not_called()

    def test_dispatch_queues_reviewed_record_and_rejects_paths_and_urls(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[])
        token = service.addon_catalog.register({'records':[self.record], 'online':True})['entries'][0]['preview']
        with mock.patch.object(service.tasks, 'start_addon_install', return_value={'task':'owned'}) as start:
            self.assertEqual(service.dispatch('addons.install', {'preview':token}), {'task':'owned'})
        self.assertEqual(start.call_args.args[:2], (self.record, self.path))
        for params in ({'url': self.entry.url}, {'preview': '/arbitrary/path'}, {'preview': token, 'path':'/tmp'}):
            with self.assertRaises(ValueError):
                service.dispatch('addons.install', params)

    def test_running_owned_session_blocks_install_without_consuming_preview(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[])
        token = service.addon_catalog.register({'records':[self.record], 'online':True})['entries'][0]['preview']
        service.sessions.items = {'agent':mock.Mock(process=mock.Mock(poll=lambda: None))}
        with mock.patch.object(service.tasks, 'start_addon_install') as start:
            with self.assertRaises(ValueError):
                service.dispatch('addons.install', {'preview':token})
        start.assert_not_called()
        self.assertIn(token, service.addon_catalog.previews)

    def test_running_install_blocks_new_sessions_and_registry_changes(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[])
        service.tasks.items['install'] = Task(mock.Mock(), 'addons.install')
        with mock.patch.object(service.tasks, 'poll'):
            for method, params in [('sessions.start',{}), ('setup.apply',{'enabled':[]}),
                                   ('addons.set_enabled',{'id':self.entry.id, 'enabled':True})]:
                with self.subTest(method=method), self.assertRaises(ValueError):
                    service.dispatch(method, params)

    def test_addon_commit_cannot_be_cancelled(self):
        tasks = Tasks()
        tasks.items['install'] = Task(mock.Mock(), 'addons.install')
        with mock.patch.object(tasks, 'poll'), mock.patch.object(tasks, '_close') as close:
            with self.assertRaises(ValueError):
                tasks.cancel('install')
        close.assert_not_called()

    def test_install_completion_preserves_enable_choices_and_reports_load_state(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[addons.Addon(Path('/fixture'), id=self.entry.id, state='verified')])
        before = self.path.read_bytes()
        result = service.finish_addon_install({'ok':True, 'id':self.entry.id, 'version':self.entry.version})
        service.adapters.reload.assert_called_once_with({'saved-ui'})
        self.assertFalse(result['enabled'])
        self.assertFalse(result['loaded'])
        self.assertEqual(self.path.read_bytes(), before)

    def test_disabling_online_access_refuses_install_without_consuming_preview(self):
        service = flutter_backend.Service(self.path)
        service.adapters = mock.Mock(items=[])
        token = service.addon_catalog.register({'records':[self.record], 'online':True})['entries'][0]['preview']
        service.dispatch('settings.update', {'values': {'addons_online':False}})
        with self.assertRaises(ValueError):
            service.dispatch('addons.install', {'preview':token})
        self.assertIn(token, service.addon_catalog.previews)

    def test_detached_and_new_install_serialize_and_recheck_version_under_lock(self):
        root = self.path.parent
        (root / 'version').write_text('1.0.0')
        script = r"""
import json, sys, time
from pathlib import Path
from dataclasses import asdict
import addons, addon_store, flutter_addon_catalog as api
root = Path(sys.argv[1])
addons.USER_DIR = root / 'addons'
entry = addon_store.Entry('fixture', 'Fixture', '2.0.0', kind='agent')
addon_store.catalog = lambda **kw: [entry]
def installed():
    return {'fixture': addons.Addon(root/'addons/fixture', id='fixture', version=(root/'version').read_text(), state='verified')}
api.installed = installed
def install(selected):
    time.sleep(0.2)
    with (root/'calls').open('a') as out:
        out.write('install\n')
    (root/'version').write_text(selected.version)
    return addons.Addon(root/'addons/fixture', id='fixture', version=selected.version, state='verified')
addon_store.install = install
body = json.dumps({'record': {'entry':asdict(entry), 'installed_version':'1.0.0'}, 'settings_path':str(root/'settings.json')}).encode()
try:
    api.execute(body)
    print('ok')
except ValueError:
    print('stale')
"""
        children = [subprocess.Popen([sys.executable,'-c',script,str(root)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        try:
            results = []
            for child in children:
                stdout, stderr = child.communicate(timeout=5)
                self.assertEqual(child.returncode, 0, stderr.decode())
                results.append(stdout.decode().strip())
            self.assertEqual(sorted(results), ['ok','stale'])
            self.assertEqual((root/'version').read_text(), '2.0.0')
            self.assertEqual((root/'calls').read_text().splitlines(), ['install'])
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                    child.communicate()
