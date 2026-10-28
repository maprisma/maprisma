import json
from types import SimpleNamespace
import unittest
from unittest import mock
import agents
import flutter_map_instances as api


class InstancesTest(unittest.TestCase):
    def setUp(self):
        self.api=api.Instances()
        self.sessions=SimpleNamespace(items={})
        self.instance=SimpleNamespace(pid=123,started=100.0,cwd='/project')
        patches=[mock.patch.object(agents,'list_agents',return_value=[agents.Agent('fixture','Fixture','',installed=True)]),
                 mock.patch.object(api.agent_terminals,'instances',return_value=[self.instance]),
                 mock.patch.object(api.provider_watch,'agent_instances',return_value={})]
        for p in patches:p.start();self.addCleanup(p.stop)

    def test_only_short_lived_single_use_handle_can_stop(self):
        preview=self.api.preview({'command':'fixture'},self.sessions)['instances'][0]['preview']
        queue=mock.Mock(return_value={'task':'t'})
        self.assertEqual(self.api.apply({'preview':preview},queue),{'task':'t'})
        self.assertEqual(json.loads(queue.call_args.args[1]),{'command':'fixture','pid':123,'started':100.0})
        with self.assertRaises(ValueError):self.api.apply({'preview':preview},queue)
        with self.assertRaises(ValueError):self.api.apply({'pid':123},queue)

    def test_expired_preview_and_frontend_pid_refused(self):
        preview=self.api.preview({'command':'fixture'},self.sessions)['instances'][0]['preview']
        with mock.patch.object(api.time,'monotonic',return_value=10**15),self.assertRaises(ValueError):
            self.api.apply({'preview':preview},mock.Mock())
        with self.assertRaises(ValueError):self.api.preview({'command':'fixture','pid':123},self.sessions)

    def test_worker_rechecks_membership_before_pidfd_stop(self):
        body=json.dumps({'command':'fixture','pid':123,'started':100.0}).encode()
        with mock.patch.object(api.agent_terminals,'stop') as stop,self.assertRaises(ValueError):api.execute(body)
        stop.assert_not_called()
        def found(commands,pids):pids['fixture']=[123]
        with mock.patch.object(api.provider_watch,'agent_instances',side_effect=found),mock.patch.object(api.agent_terminals,'stop',return_value=True) as stop:
            self.assertTrue(api.execute(body)['ok']);stop.assert_called_once_with(123,100.0)
