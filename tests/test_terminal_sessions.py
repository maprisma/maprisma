"""Real PTY contracts using small Python fixtures, never an installed agent."""
import os
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

from terminal_sessions import Sessions


class TerminalSessionsTest(unittest.TestCase):
    def setUp(self):
        self.sessions = Sessions()
        self.addCleanup(self.sessions.close)

    def start(self, script, cwd=None):
        return self.sessions.start('fixture', [sys.executable, '-u', '-c', script],
                                   cwd or str(Path.home()), dict(os.environ))

    def collect(self, ident, until=None):
        text = ''
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            result = self.sessions.read(ident)
            text += result['text']
            if (until and until in text) or result['ended']:
                return text, result
            time.sleep(0.01)
        self.fail(f'Fixture timed out: {text!r}')

    def test_real_tty_controlling_group_cwd_unicode_and_exit(self):
        with tempfile.TemporaryDirectory(prefix='asterism project ') as directory:
            ident = self.start("import os; print(os.getcwd()); print(os.isatty(0)); "
                               "print(os.tcgetpgrp(0) == os.getpgrp()); print('Grüße 世界')", directory)
            text, result = self.collect(ident)
            self.assertIn(directory, text)
            self.assertEqual(text.count('True'), 2)
            self.assertIn('Grüße 世界', text)
            self.assertTrue(result['ended'])
            self.assertEqual(result['exit_code'], 0)

    def test_interactive_input_and_resize_reach_child(self):
        ident = self.start("import os; print('READY'); line=input(); "
                           "print('ANSWER:'+line); print(os.get_terminal_size())")
        self.assertIn('READY', self.collect(ident, 'READY')[0])
        self.sessions.resize(ident, 99, 37)
        reply = self.sessions.write(ident, 'hello 世界\n'.encode())
        self.assertEqual(reply['accepted'], len('hello 世界\n'.encode()))
        text, result = self.collect(ident)
        self.assertIn('ANSWER:hello 世界', text)
        self.assertIn('columns=99, lines=37', text)
        self.assertEqual(result['exit_code'], 0)

    def test_stop_reaps_child_and_closes_pty(self):
        ident = self.start("import time; print('READY'); time.sleep(30)")
        self.collect(ident, 'READY')
        session = self.sessions.items[ident]
        self.sessions.stop(ident)
        self.assertIsNotNone(session.process.poll())
        self.assertNotIn(ident, self.sessions.items)
        with self.assertRaises(OSError):
            os.fstat(session.master)

    def test_failed_spawn_does_not_register_session(self):
        with self.assertRaises(OSError):
            self.sessions.start('fixture', ['/nonexistent/asterism-fixture'], str(Path.home()), {})
        self.assertEqual(self.sessions.items, {})

    def test_closing_finished_tab_never_signals_a_potentially_reused_pid(self):
        ident = self.start("print('done')")
        self.collect(ident)
        with mock.patch('os.killpg') as signal_group:
            self.sessions.stop(ident)
        signal_group.assert_not_called()

    def test_resize_rejects_invalid_geometry(self):
        ident = self.start("import time; time.sleep(30)")
        for cols, rows in ((True, 40), (80, 0), (1001, 24), ('80', 24)):
            with self.assertRaises(ValueError):
                self.sessions.resize(ident, cols, rows)

    def test_write_after_exit_preserves_final_output(self):
        ident = self.start("print('last output')")
        self.sessions.items[ident].process.wait(timeout=3)
        self.assertEqual(self.sessions.write(ident, b'late'), {'accepted': 0, 'ended': True})
        self.assertIn('last output', self.collect(ident)[0])

    def test_cleanup_continues_after_wait_timeout(self):
        self.sessions.items = {'first': mock.Mock(), 'second': mock.Mock()}
        with mock.patch.object(self.sessions, 'stop', side_effect=[subprocess.TimeoutExpired('fixture', 1), None]) as stop:
            self.sessions.close()
        self.assertEqual(stop.call_count, 2)
        self.sessions.items.clear()

    def test_ended_agent_background_child_is_stopped_without_signalling_reused_group(self):
        script = """import os,signal,time
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
else:
    print('CHILD:'+str(pid), flush=True)
    time.sleep(0.05)
"""
        ident = self.start(script)
        text, result = self.collect(ident)
        self.assertTrue(result['ended'])
        child = int(text.split('CHILD:')[1].split()[0])
        session = self.sessions.items[ident]
        self.assertIn(child, session.children)
        with mock.patch('os.killpg') as group:
            self.sessions.stop(ident)
        group.assert_not_called()
        stat = Path(f'/proc/{child}/stat')
        try:
            state = stat.read_text().rsplit(')',1)[1].split()[0]
        except (FileNotFoundError, ProcessLookupError):
            state = None  # Reaped before or during the read is also stopped.
        # Z (a zombie) or X (dead, seen for a moment while it is reaped): stopped either way.
        self.assertIn(state, (None, 'Z', 'X'))

    def test_reused_descendant_pid_is_never_signalled(self):
        import terminal_sessions
        session = mock.Mock(children={12345:'old-birth'}, process=mock.Mock(pid=56789))
        with mock.patch('os.pidfd_open', return_value=99), \
             mock.patch.object(terminal_sessions, '_identity', return_value=(56789,56789,'new-birth')), \
             mock.patch('os.close') as close, mock.patch('signal.pidfd_send_signal') as send:
            terminal_sessions._stop_children(session)
        send.assert_not_called()
        close.assert_called_once_with(99)
