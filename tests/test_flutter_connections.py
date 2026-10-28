import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agents
import connect
import flutter_connections as api
import inventory


class FlutterConnectionsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.file = self.root / 'settings.json'
        self.old = '{"api_key":"private-test-value","skills":[]}'
        self.new = '{"api_key":"private-test-value","skills":["/example"]}'
        self.file.write_text(self.old)
        self.controller = api.Connections(self.root / 'backups')

    def plan(self):
        return connect.Plan('test-agent', '', 'example-server',
                            changes=[connect.Change(self.file, self.old, self.new)])

    def test_preview_contains_counts_and_paths_but_no_configuration_values_or_keys(self):
        preview = self.controller.keep(self.plan())
        serialized = json.dumps(preview)
        self.assertNotIn('private-test-value', serialized)
        self.assertNotIn('api_key', serialized)
        self.assertNotIn('/example', serialized)
        self.assertEqual(preview['files'], [{'path': str(self.file), 'added': 1, 'removed': 1}])
        self.assertEqual(self.file.read_text(), self.old)

    def test_apply_and_undo_use_opaque_single_use_handles_and_actual_backups(self):
        preview = self.controller.keep(self.plan())
        result = self.controller.apply(preview['plan'])
        self.assertEqual(self.file.read_text(), self.new)
        self.assertNotIn(str(self.root / 'backups'), json.dumps(result))
        with self.assertRaises(ValueError):
            self.controller.apply(preview['plan'])
        restored = self.controller.undo(result['undo'])
        self.assertEqual(self.file.read_text(), self.old)
        self.assertEqual(restored['restored'], [str(self.file)])
        with self.assertRaises(ValueError):
            self.controller.undo(result['undo'])

    def test_apply_preserves_a_file_changed_since_preview(self):
        preview = self.controller.keep(self.plan())
        self.file.write_text('changed by another application')
        with self.assertRaises(RuntimeError):
            self.controller.apply(preview['plan'])
        self.assertEqual(self.file.read_text(), 'changed by another application')

    def test_undo_does_not_overwrite_later_edits(self):
        result = self.controller.apply(self.controller.keep(self.plan())['plan'])
        self.file.write_text('later edit')
        self.assertEqual(self.controller.undo(result['undo'])['restored'], [])
        self.assertEqual(self.file.read_text(), 'later edit')

    def test_unknown_or_expired_handles_never_become_filesystem_paths(self):
        with mock.patch.object(connect, 'undo') as undo:
            with self.assertRaises(ValueError):
                self.controller.undo('/some/arbitrary/path')
            undo.assert_not_called()
        with mock.patch.object(api.time, 'monotonic', return_value=0):
            preview = self.controller.keep(self.plan())
        with mock.patch.object(api.time, 'monotonic', return_value=601):
            with self.assertRaises(ValueError):
                self.controller.apply(preview['plan'])
        self.assertEqual(self.file.read_text(), self.old)

    def test_only_discovered_items_and_installed_agents_can_be_planned(self):
        catalog = [agents.Agent('test-agent', 'Test', '', installed=True)]
        inv = inventory.Inventory(mcp=[inventory.McpServer('known-server', agents=['source-agent'])])
        with mock.patch.object(agents, 'list_agents', return_value=catalog), \
                mock.patch.object(inventory, 'collect', return_value=inv), \
                mock.patch.object(api.mcp_ctl, 'supported', return_value=True), \
                mock.patch.object(api.mcp_ctl, 'plan', return_value=self.plan()) as builder:
            for command, item in (('unknown-agent', 'known-server'), ('test-agent', 'unknown-server')):
                with self.assertRaises(ValueError):
                    self.controller.preview({'kind': 'mcp', 'command': command, 'item': item, 'remove': False})
            builder.assert_not_called()
            result = self.controller.preview({'kind': 'mcp', 'command': 'test-agent', 'item': 'known-server', 'remove': False})
            builder.assert_called_once_with('test-agent', 'known-server', sources=['source-agent'], remove=False)
            self.assertEqual(result['command'], 'test-agent')

    def test_commands_and_oversized_plans_are_not_accepted_by_configuration_bridge(self):
        plan = self.plan()
        plan.commands = [['not-a-client-command']]
        with self.assertRaises(ValueError):
            self.controller.keep(plan)
        plan.commands = []
        plan.changes[0].new = 'x' * (8 * 1024 * 1024 + 1)
        with self.assertRaises(ValueError):
            self.controller.keep(plan)
        self.assertEqual(self.controller.plans, {})

    def test_snapshot_excludes_raw_mcp_definitions(self):
        server = inventory.McpServer('known', 'url', 'example.test', ['test-agent'])
        server.raw_entry = {'headers': {'Authorization': 'private-test-value'}}
        with mock.patch.object(agents, 'list_agents', return_value=[]), \
                mock.patch.object(inventory, 'collect', return_value=inventory.Inventory(mcp=[server])):
            result = self.controller.snapshot()
        self.assertNotIn('private-test-value', json.dumps(result))
        self.assertNotIn('headers', json.dumps(result))

    def test_provider_preview_requires_a_supported_agent_and_known_chat_model(self):
        runtime = inventory.Runtime('fixture', 'Fixture', installed=True, models=['known-model', 'embed-model'])
        catalog = [agents.Agent('test-agent', 'Test', '', installed=True)]
        params = {'kind': 'provider', 'command': 'test-agent', 'item': 'fixture',
                  'remove': False, 'model': 'known-model', 'use_now': True}
        with mock.patch.object(agents, 'list_agents', return_value=catalog), \
                mock.patch.object(inventory, 'collect', return_value=inventory.Inventory(runtimes=[runtime])), \
                mock.patch.object(connect, 'SUPPORTED', ('test-agent',)), \
                mock.patch.object(connect, 'KEYS', {'fixture': 'fixture-local'}), \
                mock.patch.object(connect, 'plan', return_value=self.plan()) as build:
            for model in ('unknown-model', 'embed-model', ''):
                with self.assertRaises(ValueError):
                    self.controller.preview({**params, 'model': model})
            build.assert_not_called()
            self.controller.preview(params)
            build.assert_called_once_with('test-agent', runtime, 'known-model', True, remove=False)

    def test_provider_disconnect_ignores_a_stale_model_selection(self):
        runtime = inventory.Runtime('fixture', 'Fixture', installed=True)
        with mock.patch.object(agents, 'list_agents', return_value=[agents.Agent('test-agent', 'Test', '', installed=True)]), \
                mock.patch.object(inventory, 'collect', return_value=inventory.Inventory(runtimes=[runtime])), \
                mock.patch.object(connect, 'SUPPORTED', ('test-agent',)), \
                mock.patch.object(connect, 'KEYS', {'fixture': 'fixture-local'}), \
                mock.patch.object(connect, 'plan', return_value=self.plan()) as build:
            self.controller.preview({'kind': 'provider', 'command': 'test-agent', 'item': 'fixture',
                'remove': True, 'model': 'no-longer-installed', 'use_now': True})
        build.assert_called_once_with('test-agent', runtime, '', False, remove=True)

    def test_queue_rejection_preserves_preview_for_retry(self):
        token = self.controller.keep(self.plan())['plan']
        with self.assertRaisesRegex(ValueError, 'full'):
            self.controller.apply(token, queue=mock.Mock(side_effect=ValueError('full')))
        self.assertIn(token, self.controller.plans)
        self.assertEqual(self.file.read_text(), self.old)
        self.controller.apply(token)
        self.assertEqual(self.file.read_text(), self.new)
