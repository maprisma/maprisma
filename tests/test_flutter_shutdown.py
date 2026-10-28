"""Actual service shutdown, with isolated Python fixtures instead of real agents."""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class FlutterShutdownTest(unittest.TestCase):
    def test_repeated_termination_during_cleanup_reaps_workers_and_ptys(self):
        with tempfile.TemporaryDirectory() as directory:
            worker = Path(directory) / 'worker.py'
            worker.write_text('''import sys, signal, json, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.stdin.readline()
print(json.dumps({'type':'progress', 'fraction':0.1, 'text':'ready'}), flush=True)
time.sleep(30)
''')
            script = '''import json, os, sys, time
from pathlib import Path
import flutter_backend as fb
from flutter_tasks import Tasks
root = Path(sys.argv[1])
class Fixture(fb.Service):
    def __init__(self):
        super().__init__(root / 'settings.json')
        self.tasks = Tasks(root / 'worker.py')
    def initialize(self):
        task = self.tasks.start('runtime.start', {'key':'fixture'})['task']
        terminal = self.sessions.start('fixture', [sys.executable, '-u', '-c',
            "import signal,time; signal.signal(signal.SIGHUP,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); print('READY'); time.sleep(30)"],
            str(root), dict(os.environ))
        text = ''
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            text += self.sessions.read(terminal)['text']
            if 'READY' in text and self.tasks.status(task)['fraction'] == 0.1:
                print(json.dumps([self.tasks.items[task].process.pid, self.sessions.items[terminal].process.pid]), flush=True)
                return
            time.sleep(0.01)
        raise RuntimeError('Fixture did not become ready')
fb.Service = Fixture
fb.main()
'''
            process = subprocess.Popen([sys.executable, '-u', '-c', script, directory],
                cwd=Path(__file__).resolve().parent.parent, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                self.assertTrue(select.select([process.stderr], [], [], 5)[0], 'Fixture did not initialize')
                children = json.loads(process.stderr.readline())
                process.send_signal(signal.SIGTERM)
                time.sleep(0.05)
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=8), 0)
                for pid in children:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=8)
                for stream in (process.stdin, process.stdout, process.stderr):
                    stream.close()
