"""Development parity: provider_watch.Watcher and the Dart core's Watcher run the same scripted
scenarios (agents starting and closing, grace time, another program on the port, restarts with the
saved state, shutdown, LM Studio's controller and daemon, a runtime that stays up and is unloaded)
and run the same commands, unload the same and save the same state after every step. Skipped
without a native Dart SDK."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / 'tools'))

import provider_watch as pw  # noqa: E402

try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

BASE = {"agents": {"opencode": ["llamacpp"], "pi": ["llamacpp", "ollama"], "bad name": ["ollama"]},
        "runtimes": {"llamacpp": {"service": "llama-server", "port": 8080},
                     "ollama": {"service": "ollama", "port": 11434},
                     "evil": {"service": "x; rm -rf ~", "port": 1}}}
LMS = {"agents": {"bionic-ish": ["lmstudio"]}, "runtimes": {"lmstudio": {"service": "", "port": 1234, "control": "lms"}}}
KOBOLD = {"agents": {"pi": ["koboldcpp"]}, "runtimes": {"koboldcpp": {
    "service": "koboldcpp", "port": 5001, "stays_up": True,
    "unload": {"path": "/api/admin/reload_config", "body": {"filename": "unload_model"}}}}}

SCENARIOS = [
    {'config': BASE, 'steps': [
        {}, {'running': ['opencode']}, {'advance': 1}, {'advance': 1, 'running': ['opencode', 'pi']},
        *[{'advance': 1, 'running': ['pi']}] * 3, {'advance': 1, 'running': []}, {'advance': pw.GRACE + 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode']}, {'advance': 1, 'running': []}, {'advance': pw.GRACE + 1, 'running': ['opencode']},
        {'advance': 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode']}, {'advance': 1, 'running': [], 'busy': [8080]}, {'advance': pw.GRACE + 1},
        {'advance': 1}, {'advance': 1, 'busy': []}]},
    {'config': BASE, 'fail': True, 'steps': [
        {'running': ['opencode']}, {'advance': 10}, {'advance': pw.RETRY + 1}, {'advance': 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode']}, {'advance': 1, 'config': {"agents": {}, "runtimes": {}}}, {'advance': pw.GRACE + 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode']}, {'op': 'new', 'running': []}, {'advance': pw.GRACE + 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode']}, {'op': 'shutdown'}, {'op': 'new'}, {'advance': pw.GRACE + 1}]},
    {'config': BASE, 'steps': [
        {'running': ['opencode', 'pi']}, {'config': {"agents": {}, "runtimes": {}}, 'op': 'shutdown'}]},
    {'config': LMS, 'lms': '/fake/bin/lms', 'lms_up': False, 'steps': [
        {'running': ['bionic-ish']}, {'advance': 1, 'running': []}, {'advance': pw.GRACE + 1}]},
    {'config': LMS, 'lms': '/fake/bin/lms', 'lms_up': True, 'steps': [
        {'running': ['bionic-ish']}, {'advance': 1, 'running': []}, {'advance': pw.GRACE + 1}]},
    {'config': LMS, 'lms': None, 'steps': [{'running': ['bionic-ish']}, {'advance': 1}]},
    {'config': KOBOLD, 'steps': [
        {'running': ['pi']}, {'advance': 1, 'running': []}, {'advance': pw.GRACE + 1}, {'op': 'shutdown'}]},
]


def python_side(scenario):
    with tempfile.TemporaryDirectory() as temp:
        config, state = Path(temp) / 'c.json', Path(temp) / 'state.json'
        config.write_text(json.dumps(scenario['config']))
        clock = {'now': 0.0, 'running': set(), 'busy': set()}
        calls, states = [], []

        def make():
            watcher = pw.Watcher(config, runner=lambda argv: calls.append(['run', *argv]) or not scenario.get('fail'),
                                 clock=lambda: clock['now'],
                                 agents_now=lambda names: ({a for a in clock['running'] if a in names}, set()),
                                 busy=lambda port, _ignore: port in clock['busy'], state=state)
            watcher.lms_up = lambda: calls.append(['lms_up']) or bool(scenario.get('lms_up'))
            watcher.stop_lms = lambda argv0: calls.append(['stop_lms', argv0])
            watcher.sockets = lambda _pids: set()
            return watcher

        def unload(entry, port):
            calls.append(['unload', port, entry['unload']])
            return True

        with mock.patch.object(pw, 'unload', unload), mock.patch.object(pw, 'lms_binary', lambda: scenario.get('lms')), \
                mock.patch.object(pw, 'log', lambda _text: None):
            watcher = make()
            for index, step in enumerate(scenario['steps']):
                clock['now'] += step.get('advance', 0)
                if 'running' in step:
                    clock['running'] = set(step['running'])
                if 'busy' in step:
                    clock['busy'] = set(step['busy'])
                if 'config' in step:
                    config.write_text(json.dumps(step['config']))
                    later = time.time() + index + 1
                    os.utime(config, (later, later))
                op = step.get('op', 'tick')
                if op == 'new':
                    watcher = make()
                elif op == 'shutdown':
                    watcher.shutdown()
                else:
                    watcher.tick()
                states.append([state.read_text() if state.exists() else None, sorted(watcher.needed)])
    return {'calls': calls, 'states': states}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartProviderWatchParityTest(unittest.TestCase):
    def test_same_commands_and_saved_state(self):
        requests = [{'config': s['config'], 'steps': s['steps'], 'fail': s.get('fail', False),
                     'lms': s.get('lms'), 'lms_up': s.get('lms_up', False)} for s in SCENARIOS]
        lines = [json.dumps({'id': i, 'protocol': 1, 'method': 'dev.watch', 'params': r})
                 for i, r in enumerate(requests, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, check=True)
        replies = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.assertEqual(len(replies), len(SCENARIOS))
        for index, (scenario, reply) in enumerate(zip(SCENARIOS, replies)):
            self.assertEqual(python_side(scenario), reply, f'scenario {index}')
        # The basics hold: started once, stopped after the grace time, never a bad unit.
        first = replies[0]['calls']
        self.assertEqual(first[0], ['run', 'systemctl', '--user', 'start', 'llama-server.service'])
        self.assertIn(['run', 'systemctl', '--user', 'stop', 'ollama.service'], first)
        self.assertFalse(any('rm' in ' '.join(map(str, c)) for r in replies for c in r['calls']))
        self.assertIn(['stop_lms', '/fake/bin/lms'], replies[8]['calls'])
        self.assertNotIn(['stop_lms', '/fake/bin/lms'], replies[9]['calls'])
        self.assertTrue(any(c[0] == 'unload' for c in replies[11]['calls']))


    def test_the_services_start_and_stop_the_same(self):
        """Both watchers as real services: a fake agent process starts, the LLM's unit is started;
        it ends, the unit is stopped after the grace time; SIGTERM ends the watcher cleanly."""
        logs = {}
        for side in ('python', 'dart'):
            with tempfile.TemporaryDirectory() as temp:
                home = Path(temp)
                bin_dir = home / '.local/bin'
                bin_dir.mkdir(parents=True)
                (bin_dir / 'systemctl').write_text('#!/bin/sh\necho "$@" >> "$HOME/systemctl.log"\n')
                (bin_dir / 'opencode').write_text('#!/bin/sh\nsleep 60\n')
                for name in ('systemctl', 'opencode'):
                    os.chmod(bin_dir / name, 0o700)
                config = home / 'c.json'
                config.write_text(json.dumps({"agents": {"opencode": ["llamacpp"]},
                                              "runtimes": {"llamacpp": {"service": "llama-server", "port": 8080}}}))
                env = {'HOME': str(home), 'PATH': f'{bin_dir}:/usr/bin:/bin', 'LANG': 'C.UTF-8'}
                command = ([sys.executable, '-I', str(ROOT / 'provider_watch.py'), '--config', str(config)]
                           if side == 'python' else
                           [DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                            'bin/maprisma-core.dart', 'provider-watch', '--config', str(config)])
                watcher = subprocess.Popen(command, env=env, cwd=ROOT / 'packages/maprisma_core',
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                log = home / 'systemctl.log'
                def wait_for(count, seconds=20):
                    until = time.monotonic() + seconds
                    while time.monotonic() < until:
                        if log.exists() and len(log.read_text().splitlines()) >= count:
                            return
                        time.sleep(0.2)
                try:
                    time.sleep(3)
                    agent = subprocess.Popen([str(bin_dir / 'opencode')], env=env)
                    wait_for(1)
                    agent.kill()
                    agent.wait()
                    wait_for(2)
                    agent = subprocess.Popen([str(bin_dir / 'opencode')], env=env)
                    wait_for(3)
                finally:
                    watcher.terminate()
                    watcher.wait(timeout=30)
                    agent.kill()
                    agent.wait()
                state = json.loads((home / '.local/state/maprisma/provider-watch.json').read_text())
                logs[side] = (log.read_text().splitlines(), state)
        self.assertEqual(logs['python'], logs['dart'])
        self.assertEqual(logs['dart'][0], ['--user start llama-server.service', '--user stop llama-server.service',
                                           '--user start llama-server.service'])
        # Stopped with the agent still open: the unit stays saved to be stopped later.
        self.assertEqual(logs['dart'][1]['pending'], {'llamacpp': {'port': 8080, 'service': 'llama-server'}})

if __name__ == '__main__':
    unittest.main()
