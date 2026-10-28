import unittest
from types import SimpleNamespace
from unittest.mock import Mock
from flutter_task_focus import resolve
from flutter_backend import Service


class TaskFocusTests(unittest.TestCase):
    def setUp(self):
        self.graph = {'nodes': [{'id': ident} for ident in [
            'agent:tool', 'runtime:engine', 'model:runtime:engine:chat',
            'mcp:server', 'skills:/folder', 'cloud:remote']], 'edges': []}

    def test_preview_anchors_are_existing_ids(self):
        self.assertEqual(resolve(self.graph, {'command': 'tool', 'kind': 'provider',
            'item': 'engine', 'model': 'Chat'}),
            ['agent:tool', 'runtime:engine', 'model:runtime:engine:chat'])
        self.assertEqual(resolve(self.graph, {'command': 'unknown', 'key': 'missing'}), [])

    def test_mcp_skills_and_addon(self):
        self.assertEqual(resolve(self.graph, {'kind': 'mcp', 'item': 'server'}), ['mcp:server'])
        self.assertEqual(resolve(self.graph, {'kind': 'skills', 'item': '/folder'}), ['skills:/folder'])
        addon = SimpleNamespace(kind='provider', provides=['remote', 'engine', 'absent'])
        self.assertEqual(resolve(self.graph, {}, addon), ['runtime:engine', 'cloud:remote'])

    def test_dispatch_enriches_only_successful_replies_without_scanning(self):
        service = Service.__new__(Service)
        service._map_result = self.graph
        service.adapters = None
        service._dispatch = Mock(return_value={'preview': 'private-handle'})
        reply = service.dispatch('agents.action_preview', {'command': 'tool'})
        self.assertEqual(reply, {'preview': 'private-handle', 'focus': ['agent:tool']})
        service._dispatch.side_effect = ValueError('rejected')
        with self.assertRaises(ValueError):
            service.dispatch('agents.action_preview', {'command': 'tool'})

    def test_provider_start_and_catalog_focus(self):
        service = Service.__new__(Service)
        service._map_result = self.graph
        service.adapters = SimpleNamespace(items=[SimpleNamespace(id='addon', kind='agent', provides=['tool'])])
        service._dispatch = Mock(return_value={'task': 'opaque'})
        self.assertEqual(service.dispatch('providers.run', {'operation': 'model.load',
            'params': {'key': 'engine', 'model': 'chat'}})['focus'],
            ['runtime:engine', 'model:runtime:engine:chat'])
        service.addon_catalog = Mock()
        service.addon_catalog.register.return_value = {'entries': [{'id': 'addon'}]}
        self.assertEqual(service.catalog_focus({})['entries'][0]['focus'], ['agent:tool'])

    def test_runtime_records_supply_review_focus_without_frontend_id_rules(self):
        service = Service.__new__(Service)
        service._map_result = self.graph
        service.adapters = None
        service._dispatch = Mock(return_value={'local': [{'key': 'engine'}]})
        self.assertEqual(service.dispatch('providers.snapshot', {})['local'][0]['focus'], ['runtime:engine'])
