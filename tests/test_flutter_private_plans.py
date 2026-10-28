import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import connect
from flutter_connections import Connections
from flutter_tasks import Tasks
import flutter_plan_wire
import inventory


class PrivatePlanTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.file = self.root / 'settings.json'
        self.old = '{"api_key":"private-fixture-value","model":"old"}'
        self.new = '{"api_key":"private-fixture-value","model":"new"}'
        self.file.write_text(self.old)
        self.worker = self.root / 'worker.py'
        source = str(Path(__file__).resolve().parent.parent)
        self.worker.write_text(f'''import sys
sys.path.insert(0, {source!r})
from unittest import mock
import ai_core, flutter_worker
from flutter_addons import AdapterRegistry
with mock.patch.object(AdapterRegistry, 'reload'), mock.patch.object(ai_core, 'setting', return_value=[]):
    flutter_worker.main()
''')
        self.tasks = Tasks(self.worker)
        self.addCleanup(self.tasks.close)
        self.connections = Connections(self.root / 'backups')

    def plan(self, contexts=()):
        return connect.Plan('test-agent', 'fixture', 'fixture-local',
            changes=[connect.Change(self.file, self.old, self.new)], contexts=list(contexts))

    def result(self, ident):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            result = self.tasks.status(ident)
            if result['state'] != 'running':
                return result
            time.sleep(0.01)
        self.fail('Private worker timed out')

    def test_actual_worker_applies_private_plan_and_exposes_only_an_undo_handle(self):
        preview = self.connections.keep(self.plan())
        queued = self.connections.apply(preview['plan'], self.tasks.start_plan)
        status = self.result(queued['task'])
        self.assertEqual(status['state'], 'done')
        self.assertEqual(self.file.read_text(), self.new)
        public = json.dumps(status)
        self.assertNotIn('private-fixture-value', public)
        self.assertNotIn(str(self.root / 'backups'), public)
        self.assertNotIn('private-fixture-value', str(self.tasks.items[queued['task']].process.args))
        self.connections.undo(status['result']['undo'])
        self.assertEqual(self.file.read_text(), self.old)

    def test_worker_refuses_a_file_changed_after_preview(self):
        preview = self.connections.keep(self.plan())
        self.file.write_text('a later edit')
        queued = self.connections.apply(preview['plan'], self.tasks.start_plan)
        self.assertEqual(self.result(queued['task'])['state'], 'failed')
        self.assertEqual(self.file.read_text(), 'a later edit')

    def test_context_failure_preserves_configuration_backup_and_undo(self):
        runtime = inventory.Runtime('fixture', 'Fixture', installed=True)
        preview = self.connections.keep(self.plan([(runtime, 'known-model', 8192)]))
        self.assertEqual(preview['contexts'][0]['tokens'], 8192)
        queued = self.connections.apply(preview['plan'], self.tasks.start_plan)
        status = self.result(queued['task'])
        self.assertEqual(status['state'], 'done')
        self.assertEqual(status['result']['context_failures'], 1)
        self.assertEqual(self.file.read_text(), self.new)
        self.connections.undo(status['result']['undo'])
        self.assertEqual(self.file.read_text(), self.old)

    def test_context_only_plan_is_not_reported_as_empty(self):
        plan = connect.Plan('test-agent', 'fixture', 'fixture-local',
                            contexts=[(inventory.Runtime('fixture', 'Fixture'), 'known-model', 4096)])
        self.assertFalse(self.connections.keep(plan)['empty'])

    def test_worker_adds_and_removes_skill_links_with_undo(self):
        source = self.root / 'skills' / 'example'
        source.mkdir(parents=True)
        (source / 'SKILL.md').write_text('skill')
        link = self.root / 'agent-skills' / 'example'
        for remove in (False, True):
            plan = connect.Plan('test-agent', '', '', **{
                'links_remove' if remove else 'links_add': [(link, source)]})
            preview = self.connections.keep(plan)
            task = self.connections.apply(preview['plan'], self.tasks.start_plan)
            status = self.result(task['task'])
            self.assertEqual(status['state'], 'done')
            self.assertEqual(link.is_symlink(), not remove)
            self.connections.undo(status['result']['undo'])
            self.assertEqual(link.is_symlink(), remove)
            if not remove:
                link.parent.mkdir(exist_ok=True)
                link.symlink_to(source)

    def test_worker_refuses_skill_sources_removed_after_preview(self):
        source = self.root / 'skill'
        source.mkdir()
        marker = source / 'SKILL.md'
        marker.write_text('skill')
        link = self.root / 'links' / 'skill'
        preview = self.connections.keep(connect.Plan('', '', '', links_add=[(link, source)]))
        marker.unlink()
        task = self.connections.apply(preview['plan'], self.tasks.start_plan)
        self.assertEqual(self.result(task['task'])['state'], 'failed')
        self.assertFalse(link.is_symlink())

    def test_worker_preserves_link_collision_after_preview(self):
        source = self.root / 'skill'
        source.mkdir()
        (source / 'SKILL.md').write_text('skill')
        link = self.root / 'collision'
        preview = self.connections.keep(connect.Plan('', '', '', links_add=[(link, source)]))
        link.write_text('new user file')
        task = self.connections.apply(preview['plan'], self.tasks.start_plan)
        self.assertEqual(self.result(task['task'])['state'], 'failed')
        self.assertEqual(link.read_text(), 'new user file')

    def test_wire_round_trip_and_path_validation_for_links(self):
        source, link = self.root / 'source', self.root / 'link'
        plan = connect.Plan('', '', '', links_add=[(link, source)], links_remove=[(link, Path('../relative-original'))])
        decoded, _ = flutter_plan_wire.decode(flutter_plan_wire.encode(plan, self.root / 'backups'))
        self.assertEqual(decoded.links_add, plan.links_add)
        self.assertEqual(decoded.links_remove, plan.links_remove)
        for links in [[(Path('relative'), source)], [(link, Path('relative'))]]:
            with self.assertRaises(ValueError):
                flutter_plan_wire.encode(connect.Plan('', '', '', links_add=links), self.root / 'backups')

    def test_generic_provider_endpoint_cannot_start_private_operations(self):
        with self.assertRaises(ValueError):
            self.tasks.start('connections.apply', {'path': str(self.file)})
        with self.assertRaises(ValueError):
            self.tasks.start('models.remove', {'path': str(self.file)})
        self.assertEqual(self.tasks.items, {})

    def test_private_wire_refuses_commands_and_invalid_backup_roots(self):
        plan = self.plan()
        plan.commands = [['arbitrary-command']]
        with self.assertRaises(ValueError):
            flutter_plan_wire.encode(plan, self.root / 'backups')
        plan.commands = []
        body = json.loads(flutter_plan_wire.encode(plan, self.root / 'backups'))
        body['backup_root'] = 'relative'
        with self.assertRaises(ValueError):
            flutter_plan_wire.decode(json.dumps(body).encode())
        with self.assertRaises(ValueError):
            self.connections.register_backup({'backup': str(self.root)})

    def test_private_worker_requires_a_safe_result_filter(self):
        with self.assertRaises(ValueError):
            self.tasks.start_plan(self.plan(), self.root / 'backups', None)

    def test_removal_record_reaches_worker_over_private_fd(self):
        source = str(Path(__file__).resolve().parent.parent)
        self.worker.write_text(f'''import sys
sys.path.insert(0, {source!r})
from unittest import mock
import ai_core, flutter_worker, flutter_removals
from flutter_addons import AdapterRegistry
def execute(record):
    assert record == {{'private_fixture': 'private-removal-value'}}
    return {{'ok': True, 'recoverable': True}}
with mock.patch.object(AdapterRegistry, 'reload'), mock.patch.object(ai_core, 'setting', return_value=[]), mock.patch.object(flutter_removals, 'execute', side_effect=execute):
    flutter_worker.main()
''')
        queued = self.tasks.start_removal({'private_fixture': 'private-removal-value'})
        result = self.result(queued['task'])
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['result'], {'ok': True, 'recoverable': True})
        self.assertNotIn('private-removal-value', json.dumps(result))
        self.assertNotIn('private-removal-value', str(self.tasks.items[queued['task']].process.args))

    def test_running_commits_cannot_be_cancelled_mid_write(self):
        self.worker.write_text('import time\ntime.sleep(30)\n')
        queued = self.tasks.start_removal({'version': 1})
        with self.assertRaises(ValueError):
            self.tasks.cancel(queued['task'])
        self.assertIsNone(self.tasks.items[queued['task']].process.poll())
