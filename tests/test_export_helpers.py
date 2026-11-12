"""tools/export-helpers.py: the AI helpers of the adapters for the other Maprisma apps (data/helpers.json)."""
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import adapter_data  # noqa: E402

_spec = importlib.util.spec_from_file_location('export_helpers', ROOT / 'tools/export-helpers.py')
export_helpers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(export_helpers)


class ExportHelpersTest(unittest.TestCase):
    def test_the_committed_file_is_up_to_date(self):
        result = subprocess.run([sys.executable, '-I', str(ROOT / 'tools/export-helpers.py'), '--check'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_the_file_has_the_format_callers_read(self):
        content = json.loads((ROOT / 'data/helpers.json').read_text())
        self.assertEqual(set(content), {'version', 'helpers'})
        self.assertIsInstance(content['version'], int)
        self.assertGreaterEqual(content['version'], 1)
        for entry in content['helpers']:
            with self.subTest(helper=entry['id']):
                self.assertEqual(set(entry), {'id', 'name', 'command', 'ask', 'task', 'verified'})
                self.assertTrue(entry['ask'] or entry['task'])
                self.assertIsInstance(entry['verified'], bool)
                if entry['ask']:
                    self.assertEqual(set(entry['ask']), {'argv', 'stdin'})
                    self.assertEqual(entry['ask']['argv'][0], entry['command'])
                    self.assertEqual(entry['ask']['stdin'], '{prompt}' not in entry['ask']['argv'])
                    self.assertNotIn('{effort}', entry['ask']['argv'])
                if entry['task']:
                    self.assertEqual(set(entry['task']), {'argv'})
                    self.assertEqual(entry['task']['argv'][0], entry['command'])
                    self.assertEqual(entry['task']['argv'].count('{prompt}'), 1)
                for argv in (entry['ask'] or {}).get('argv', []), (entry['task'] or {}).get('argv', []):
                    self.assertFalse([a for a in argv if re.search(r'\{[a-z]+\}', a) and a != '{prompt}'], argv)

    def test_every_adapter_with_an_ask_or_a_task_is_a_helper_in_preference_order(self):
        ids = [entry['id'] for entry in export_helpers.helpers()]
        able = sorted(path.stem for path in adapter_data.ADAPTERS.glob('*.toml')
                      if {'ask', 'task'} & set(tomllib.loads(path.read_text())))
        self.assertEqual(sorted(ids), able)
        first = [c for c in export_helpers.PREFERRED if c in ids]
        self.assertEqual(ids[:len(first)], first)
        self.assertEqual(ids[len(first):], sorted(ids[len(first):]))
        self.assertEqual(ids[:2], ['claude', 'codex'])

    def test_the_known_entries(self):
        found = {entry['id']: entry for entry in export_helpers.helpers()}
        claude = found['claude']
        self.assertEqual(claude['task'], {'argv': ['claude', '{prompt}']})
        self.assertEqual(claude['ask']['argv'][:2], ['claude', '-p'])
        self.assertIs(claude['verified'], True)
        self.assertIsNone(found['opencode']['ask'])     # helper = false: its shell is not switched off
        self.assertIsNotNone(found['opencode']['task'])
        self.assertNotIn('crush', found)
        hermes = found['hermes']['ask']['argv']         # Thinking time left out: the agent's default
        self.assertEqual(hermes[0], 'hermes')
        self.assertNotIn('{effort}', hermes)

    def test_entries_and_version(self):
        def entry(text):
            return export_helpers.helper('x', tomllib.loads('command = "x"\nname = "X"\n' + text))
        self.assertIsNone(entry(''))
        self.assertEqual(entry('[task]\nargv = ["x", "{prompt}"]\nverified = false\n'),
                         {'id': 'x', 'name': 'X', 'command': 'x', 'ask': None,
                          'task': {'argv': ['x', '{prompt}']}, 'verified': False})
        self.assertEqual(entry('[ask]\nargv = ["x", "{effort}", "-p", "{prompt}"]\n')['ask'],
                         {'argv': ['x', '-p', '{prompt}'], 'stdin': False})
        for bad in ('[task]\nargv = ["sh", "-c", "{prompt}"]\n', '[task]\nargv = ["x"]\n',
                    '[ask]\nargv = ["x", "--q={prompt}"]\n'):
            with self.subTest(bad=bad), self.assertRaises(export_helpers.ExportError):
                entry(bad)
        helpers = [{'id': 'x'}]
        self.assertEqual(export_helpers.export(None, helpers), {'version': 1, 'helpers': helpers})
        self.assertEqual(export_helpers.export({'version': 4, 'helpers': helpers}, helpers)['version'], 4)
        self.assertEqual(export_helpers.export({'version': 4, 'helpers': []}, helpers)['version'], 5)

    def test_an_unverified_entry_is_exported_but_not_used_by_the_app(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'claude.toml'
            text = (ROOT / 'adapters/claude.toml').read_text().replace(
                'argv = ["claude", "{prompt}"]\n', 'argv = ["claude", "{prompt}"]\nverified = false\n', 1)
            self.assertIn('verified = false', text)
            path.write_text(text)
            harness = adapter_data.load(path)
            self.assertEqual(harness.task, ())
            self.assertTrue(harness.ask)
            self.assertIs(export_helpers.helper('claude', tomllib.loads(text))['verified'], False)


if __name__ == '__main__':
    unittest.main()
