import tempfile
import time
import os
import sys
import unittest
from pathlib import Path

from flutter_tasks import Tasks


class FlutterTasksTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.worker = Path(temp.name) / 'worker.py'
        self.tasks = Tasks(self.worker)
        self.addCleanup(self.tasks.close)

    def until_finished(self, ident):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            status = self.tasks.status(ident)
            if status['state'] != 'running':
                return status
            time.sleep(0.01)
        self.fail('Fixture worker timed out')

    def test_process_reports_progress_and_result_without_blocking_start(self):
        self.worker.write_text('''import json, sys, time
request = json.loads(sys.stdin.readline())
print(json.dumps({'type':'progress', 'fraction':0.5, 'text':'half'}), flush=True)
time.sleep(0.05)
print(json.dumps({'type':'result', 'result':{'key':request['params']['key']}}), flush=True)
''')
        ident = self.tasks.start('runtime.start', {'key': 'fixture'})['task']
        self.assertEqual(self.tasks.items[ident].state, 'running')
        result = self.until_finished(ident)
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['fraction'], 0.5)
        self.assertEqual(result['result'], {'key': 'fixture'})

    def test_cancel_reaps_owned_worker_and_keeps_service_available(self):
        self.worker.write_text('import sys, time\nsys.stdin.readline()\ntime.sleep(30)\n')
        ident = self.tasks.start('runtime.start', {'key': 'fixture'})['task']
        process = self.tasks.items[ident].process
        self.assertEqual(self.tasks.cancel(ident)['state'], 'stopped')
        self.assertIsNotNone(process.poll())

    def test_malformed_worker_reply_fails_without_returning_private_text(self):
        self.worker.write_text('import sys\nsys.stdin.readline()\nprint("not JSON; private data", flush=True)\n')
        ident = self.tasks.start('runtime.start', {'key': 'fixture'})['task']
        result = self.until_finished(ident)
        self.assertEqual(result['state'], 'failed')
        self.assertEqual(result['result'], {})
        self.assertEqual(result['text'], '')

    def test_unknown_operations_never_spawn_a_process(self):
        with self.assertRaises(ValueError):
            self.tasks.start('shell.exec', {'argv': ['sh']})
        self.assertEqual(self.tasks.items, {})

    def test_late_cancel_preserves_a_completed_result(self):
        self.worker.write_text('import sys, json\nsys.stdin.readline()\n'
                               'print(json.dumps({"type":"result","result":{"ok":True}}),flush=True)\n')
        ident = self.tasks.start('runtime.start', {'key': 'fixture'})['task']
        self.until_finished(ident)
        result = self.tasks.cancel(ident)
        self.assertEqual(result['state'], 'done')
        self.assertEqual(result['result'], {'ok': True})

    def test_stdio_service_can_read_a_terminal_while_an_operation_runs(self):
        from flutter_backend import Service
        self.worker.write_text('import sys, time\nsys.stdin.readline()\ntime.sleep(30)\n')
        service = Service(self.worker.parent / 'settings.json')
        service.tasks = self.tasks
        self.addCleanup(service.sessions.close)
        task = service.dispatch('providers.run', {'operation': 'runtime.start', 'params': {'key': 'fixture'}})['task']
        terminal = service.sessions.start('fixture', [sys.executable, '-u', '-c',
            "import time; print('READY'); time.sleep(30)"], str(self.worker.parent), dict(os.environ))
        deadline = time.monotonic() + 2
        text = ''
        while time.monotonic() < deadline and 'READY' not in text:
            text += service.dispatch('sessions.read', {'session': terminal})['text']
            time.sleep(0.01)
        self.assertIn('READY', text)
        self.assertEqual(self.tasks.items[task].state, 'running')

    def test_close_waits_for_commit_worker_without_signalling_it(self):
        for operation in ('connections.apply', 'addons.install', 'installers.install', 'existing.apply'):
            with self.subTest(operation=operation):
                marker = self.worker.parent / ('committed-' + operation)
                self.worker.write_text('import sys,time,json\nfrom pathlib import Path\nsys.stdin.readline()\n'
                    + 'time.sleep(0.15)\nPath(' + repr(str(marker)) + ').write_text("complete")\n'
                    + 'print(json.dumps({"type":"result","result":{"ok":True}}),flush=True)\n')
                ident = self.tasks._spawn(operation, {})['task']
                self.tasks.close()
                self.assertEqual(marker.read_text(), 'complete')
                self.assertEqual(self.tasks.items[ident].process.returncode, 0)

    def test_slow_snapshot_does_not_block_terminal_reads(self):
        from flutter_backend import Service
        self.worker.write_text('import sys,time\nsys.stdin.readline()\ntime.sleep(30)\n')
        service = Service(self.worker.parent / 'settings.json')
        service.tasks = self.tasks
        self.addCleanup(service.sessions.close)
        terminal = service.sessions.start('fixture', [sys.executable, '-u', '-c', "print('READY')"], str(self.worker.parent), dict(os.environ))
        self.assertEqual(service.dispatch('map.snapshot', {})['nodes'], [])
        text = ''
        deadline = time.monotonic() + 2
        while 'READY' not in text and time.monotonic() < deadline:
            text += service.dispatch('sessions.read', {'session': terminal})['text']
            time.sleep(0.01)
        self.assertIn('READY', text)

    def test_snapshot_reuses_process_and_scan_slots_do_not_consume_work_capacity(self):
        self.worker.write_text('''import sys,json,os
for line in sys.stdin:
    print(json.dumps({'type':'result','result':{'pid':os.getpid()}}),flush=True)
''')
        first = self.tasks.start_snapshot(None, [])['task']
        pid = self.until_finished(first)['result']['pid']
        second = self.tasks.start_snapshot(None, [])['task']
        self.assertEqual(second, first)
        self.assertEqual(self.until_finished(second)['result']['pid'], pid)
        # Four real operations may run while the persistent scanner is alive.
        self.worker.write_text('import sys,time\nsys.stdin.readline()\ntime.sleep(30)\n')
        ids = [self.tasks.start('runtime.start', {'key':'fixture'})['task'] for _ in range(4)]
        self.assertEqual(len(ids), 4)
        with self.assertRaises(ValueError):
            self.tasks.start('runtime.start', {'key':'fixture'})
        self.assertIn('task', self.tasks.start_setup(None))
