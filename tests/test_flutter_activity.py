import json
from types import SimpleNamespace
import unittest
from unittest import mock

import agents
import flutter_activity as api
import subagents


class FlutterActivityTest(unittest.TestCase):
    def test_external_sessions_and_owned_fallback_are_counted_without_duplicates(self):
        catalog = [agents.Agent('fixture', 'Fixture', '', installed=True)]
        def instances(names, pids):
            pids['fixture'] = [11]
            return {'fixture': [['--model', 'known']]}
        sessions = SimpleNamespace(items={
            'same': SimpleNamespace(command='fixture', process=mock.Mock(pid=11, poll=lambda: None)),
            'missing': SimpleNamespace(command='fixture', process=mock.Mock(pid=12, poll=lambda: None)),
        })
        child = subagents.SubAgent('fixture', 'child-id', 'worker', 'private task description', '/project', True, 2)
        with mock.patch.object(api.provider_watch, 'agent_instances', side_effect=instances), \
                mock.patch.object(api.subagents, 'where', return_value=('supported', '/fixture')), \
                mock.patch.object(api.subagents, 'of', return_value=[child]):
            running, activity = api.snapshot(catalog, sessions)
        self.assertEqual(running['fixture'], ['known', ''])
        self.assertEqual(activity['fixture']['instances'], 2)
        self.assertEqual(activity['fixture']['active_subagents'], 1)
        self.assertNotIn('private task description', json.dumps(activity))

    def test_unsupported_format_is_unknown_not_zero(self):
        with mock.patch.object(api.provider_watch, 'agent_instances', return_value={}), \
                mock.patch.object(api.subagents, 'where', return_value=()):
            _, result = api.snapshot([agents.Agent('fixture', 'Fixture', '', installed=True)], SimpleNamespace(items={}))
        self.assertIsNone(result['fixture']['active_subagents'])
        self.assertFalse(result['fixture']['subagents_supported'])
