"""Named, reviewed actions and isolated test completion. Never starts real agents."""
from pathlib import Path
import os
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import agents
import ai_core
import first_agent
import flutter_agent_actions as api
import flutter_backend
import harnesses
import install_recipes
import signin


class AgentActionsTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name)/'settings.json'
        self.agent = agents.Agent('fixture','Fixture','', installed=True, source='mise')
        self.harness = SimpleNamespace(install=(),data=('~/fixture-data',),ask=('fixture','--ask','{prompt}'),
            access=lambda: SimpleNamespace(logins=(signin.Login('Test account',('fixture','login')),)))
        self.enterContext(mock.patch.object(agents,'list_agents',return_value=[self.agent]))
        self.enterContext(mock.patch.object(harnesses,'get',return_value=self.harness))
        self.enterContext(mock.patch.object(ai_core,'add_user_program_dirs'))
        self.enterContext(mock.patch.object(api.shutil,'which',side_effect=lambda program:'/fixture/'+program))
        self.actions = api.Actions(self.path)
        self.addCleanup(self.actions.close)
        self.sessions = mock.Mock(items={})
        self.sessions.start.return_value = 'owned'

    def test_rejects_arbitrary_commands_paths_unknown_agents_and_invalid_login_indices(self):
        for params in ({'command':'fixture','action':'login','argv':['sh']},
                       {'command':'fixture','action':'run'}, {'command':'absent','action':'login'},
                       {'command':'fixture','action':'login','login':True},
                       {'command':'fixture','action':'login','login':99}):
            if params.get('command') == 'absent':
                with mock.patch.object(harnesses,'get',return_value=None), self.assertRaises(ValueError):
                    self.actions.preview(params)
            else:
                with self.assertRaises(ValueError):
                    self.actions.preview(params)
        self.sessions.start.assert_not_called()

    def test_login_uses_registered_argv_and_is_single_use(self):
        plan = self.actions.preview({'command':'fixture','action':'login'})
        self.assertEqual(plan['logins'], ['Test account'])
        result = self.actions.apply(plan['preview'],self.sessions)
        self.assertEqual(result['session'],'owned')
        self.assertEqual(self.sessions.start.call_args.args[1],['/fixture/fixture','login'])
        with self.assertRaises(ValueError):
            self.actions.apply(plan['preview'],self.sessions)

    def test_logout_uses_registered_argv_and_rechecks_before_launch(self):
        self.harness.logout=('fixture','logout')
        plan=self.actions.preview({'command':'fixture','action':'logout'})
        self.assertEqual(plan['commands'],['/fixture/fixture logout'])
        self.harness.logout=('fixture','changed-logout')
        with self.assertRaises(ValueError):self.actions.apply(plan['preview'],self.sessions)
        self.sessions.start.assert_not_called()

    def test_changed_recipe_or_install_state_requires_new_review(self):
        token = self.actions.preview({'command':'fixture','action':'login'})['preview']
        self.harness.access=lambda:SimpleNamespace(logins=(signin.Login('Different account',('fixture','other-login')),))
        with self.assertRaises(ValueError):
            self.actions.apply(token,self.sessions)
        self.sessions.start.assert_not_called()

    def test_expired_preview_never_starts_a_process(self):
        with mock.patch.object(api.time,'monotonic',return_value=0):
            token=self.actions.preview({'command':'fixture','action':'login'})['preview']
        with mock.patch.object(api.time,'monotonic',return_value=301),self.assertRaises(ValueError):
            self.actions.apply(token,self.sessions)
        self.sessions.start.assert_not_called()

    def test_external_install_uses_existing_recipe_and_retains_handle_on_launch_failure(self):
        step=install_recipes.Step('mise',['mise use -g fixture'],[['mise','use','-g','fixture']])
        with mock.patch.object(install_recipes,'choose',return_value=step), \
             mock.patch.object(install_recipes,'run',side_effect=[False,True]) as run:
            token=self.actions.preview({'command':'fixture','action':'install'})['preview']
            with self.assertRaises(ValueError):
                self.actions.apply(token,self.sessions)
            self.assertIn(token,self.actions.previews)
            self.assertEqual(self.actions.apply(token,self.sessions),{'external':True})
        self.assertEqual(run.call_count,2)
        self.sessions.start.assert_not_called()

    def test_manual_and_internal_installer_recipes_cannot_be_executed(self):
        for step in (install_recipes.Step('manual',url='https://example.com'),
                     install_recipes.Step('installer',installer=True)):
            with mock.patch.object(install_recipes,'choose',return_value=step):
                plan=self.actions.preview({'command':'fixture','action':'install'})
                self.assertFalse(plan['runnable'])
                self.assertIsNone(plan['preview'])

    def test_removal_discloses_retained_data_and_blocks_running_owned_agent(self):
        step=install_recipes.Step('mise',['mise uninstall fixture'],[['mise','uninstall','fixture']])
        self.sessions.items={'running':SimpleNamespace(command='fixture')}
        self.sessions.poll.return_value=None
        with mock.patch.object(install_recipes,'choose',return_value=step), \
             mock.patch.object(install_recipes,'run') as run:
            plan=self.actions.preview({'command':'fixture','action':'uninstall'})
            self.assertEqual(plan['data'],['~/fixture-data'])
            with self.assertRaises(ValueError):
                self.actions.apply(plan['preview'],self.sessions)
        run.assert_not_called()

    def test_fixed_test_isolated_and_marks_only_answering_success_without_persisting_output(self):
        self.enterContext(mock.patch.object(first_agent,'verify_argv',return_value=['fixture','--ask',first_agent.TEST_PROMPT]))
        token=self.actions.preview({'command':'fixture','action':'verify'})['preview']
        self.actions.apply(token,self.sessions)
        argv,cwd,env=self.sessions.start.call_args.args[1:]
        self.assertEqual(argv[-1],first_agent.TEST_PROMPT)
        self.assertNotEqual(cwd,str(Path.home()))
        self.assertTrue(Path(cwd).is_dir())
        self.assertEqual(env['MAPRISMA_NO_PROVIDERS'],'1')
        self.actions.observe('owned',{'text':'Ready to help.','exit_code':None,'ended':False})
        self.assertFalse(self.path.exists())
        self.actions.observe('owned',{'text':'','exit_code':0,'ended':True})
        state=ai_core.load_settings(self.path)['first_agent']
        self.assertEqual(state['verified'],['fixture'])
        self.assertNotIn('answer',state)
        self.assertFalse(Path(cwd).exists())

    def test_failed_or_stopped_test_does_not_mark_agent_working(self):
        self.enterContext(mock.patch.object(first_agent,'verify_argv',return_value=['fixture','--ask',first_agent.TEST_PROMPT]))
        for code in (1,None):
            token=self.actions.preview({'command':'fixture','action':'verify'})['preview']
            self.actions.apply(token,self.sessions)
            self.actions.observe('owned',{'text':'error output','exit_code':code,'ended':True})
            self.assertFalse(self.path.exists())
        token=self.actions.preview({'command':'fixture','action':'verify'})['preview']
        self.actions.apply(token,self.sessions)
        self.actions.forget('owned')
        self.assertFalse(self.path.exists())

    def test_disk_failure_is_reported_but_does_not_hide_final_terminal_output(self):
        self.enterContext(mock.patch.object(first_agent,'verify_argv',return_value=['fixture','--ask',first_agent.TEST_PROMPT]))
        token=self.actions.preview({'command':'fixture','action':'verify'})['preview']
        self.actions.apply(token,self.sessions)
        result={'text':'Ready to help.','exit_code':0,'ended':True}
        with mock.patch.object(ai_core,'update_settings',side_effect=OSError('fixture full disk')):
            self.actions.observe('owned',result)
        self.assertTrue(result['verification_failed'])
        self.assertEqual(result['text'],'Ready to help.')
        self.assertFalse(self.actions.verifications)

    def test_service_fixed_test_reaches_real_pty_and_records_success_only_after_exit(self):
        import sys,time
        service=flutter_backend.Service(self.path)
        self.addCleanup(service.agent_actions.close)
        self.addCleanup(service.sessions.close)
        argv=[sys.executable,'-u','-c',"print('Ready to help.')",first_agent.TEST_PROMPT]
        with mock.patch.object(first_agent,'verify_argv',return_value=argv), \
             mock.patch.object(api.shutil,'which',side_effect=lambda program:sys.executable):
            plan=service.dispatch('agents.action_preview',{'command':'fixture','action':'verify'})
            result=service.dispatch('agents.action_apply',{'preview':plan['preview']})
        output=''
        deadline=time.monotonic()+4
        while time.monotonic()<deadline:
            reply=service.dispatch('sessions.read',{'session':result['session']})
            output+=reply['text']
            if reply['ended']:
                break
            time.sleep(0.01)
        self.assertTrue(reply['ended'])
        self.assertIn('Ready to help.',output)
        self.assertEqual(ai_core.load_settings(self.path)['first_agent']['verified'],['fixture'])
        self.assertFalse(Path(result['path']).exists())
