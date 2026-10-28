"""First-agent route validation and credential-presence-only checklist fixtures."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import agent_status
import agents
import ai_core
import first_agent
import flutter_first_agent as api
import inventory


class FirstAgentGuideTest(unittest.TestCase):
    def setUp(self):
        temp=tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path=Path(temp.name)/'settings.json'
        self.routes=first_agent.Catalog(routes=[first_agent.Route('online-test','online','fixture','Fixture online',needs=('node',))])
        self.enterContext(mock.patch.object(api,'catalog',return_value=self.routes))
        self.agent=agents.Agent('fixture','Fixture','',installed=True)
        self.enterContext(mock.patch.object(agents,'list_agents',return_value=[self.agent]))
        self.harness=SimpleNamespace(access=lambda:agent_status.Access('account'),ask=('fixture','{prompt}'))
        self.harness_get=self.enterContext(mock.patch.object(api.harnesses,'get',return_value=self.harness))
        self.enterContext(mock.patch.object(first_agent,'missing',return_value=[]))

    def test_choose_preserves_other_guide_state_and_rejects_unknown_routes(self):
        ai_core.update_settings(self.path,first_agent={'verified':['previous'],'later':True})
        api.choose('online-test',None,self.path)
        state=ai_core.load_settings(self.path)['first_agent']
        self.assertEqual(state,{'verified':['previous'],'later':False,'route':'online-test'})
        before=self.path.read_bytes()
        for route in ('unknown', '/arbitrary/path', [], None):
            with self.assertRaises(ValueError):
                api.choose(route,None,self.path)
        self.assertEqual(self.path.read_bytes(),before)

    def test_snapshot_uses_presence_check_without_opening_credential_files(self):
        with mock.patch.object(agent_status,'credentials_present',return_value=True) as present:
            data=api.snapshot(None,self.path)
        present.assert_called_once()
        steps=data['routes'][0]['steps']
        self.assertTrue(next(step for step in steps if step['title']=='Sign in or set an API key')['done'])
        self.assertFalse(data['routes'][0]['verified'])
        self.assertFalse(self.path.exists())

    def test_missing_adapter_leads_to_addons_and_offers_no_agent_execution(self):
        self.harness_get.return_value=None
        data=api.snapshot(None,self.path)
        steps=data['routes'][0]['steps']
        self.assertEqual(steps[0]['action'],'addons')
        self.assertFalse(any(step['action'] in ('login','verify','install') for step in steps))

    def test_local_route_links_existing_provider_and_connection_flows(self):
        self.routes.routes=[first_agent.Route('local-test','local','fixture','Fixture local',runtime='local-provider')]
        runtime=SimpleNamespace(key='local-provider',installed=True,models=['model'])
        with mock.patch.object(inventory,'collect',return_value=inventory.Inventory(runtimes=[runtime])), \
             mock.patch.object(api.providers,'get',return_value=SimpleNamespace(name='Local provider')), \
             mock.patch.object(api.connect,'is_connected',return_value=True), \
             mock.patch.object(api.connect,'is_active',return_value=True):
            data=api.snapshot(None,self.path)
        steps=data['routes'][0]['steps']
        self.assertTrue(next(step for step in steps if step['title']=='Connections')['done'])
        self.assertEqual(sum(step['action']=='providers' for step in steps),2)

    def test_malformed_old_verified_state_is_not_treated_as_success(self):
        ai_core.update_settings(self.path,first_agent={'verified':7})
        data=api.snapshot(None,self.path)
        self.assertFalse(data['routes'][0]['verified'])
