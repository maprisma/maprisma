"""The contract between the GUI and the core (tools/protocol.py, packages/maprisma_core/protocol/routes.json)."""

import json
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
import protocol  # noqa: E402


class ContractTest(unittest.TestCase):
    def test_the_contract_holds(self):
        # A new route in the core, a route the GUI calls or a parameter it sends must be in
        # routes.json, and docs/protocol.md must be made from it: tools/protocol.py update / doc.
        self.assertEqual(protocol.check(), [])

    def test_a_route_outside_the_contract_is_caught(self):
        from unittest import mock
        calls = {**protocol.gui_calls(), 'agents.brand_new': {}}
        names = protocol.core_names() | {'agents.brand_new'}
        with mock.patch.object(protocol, 'gui_calls', return_value=calls), \
                mock.patch.object(protocol, 'core_names', return_value=names):
            problems = protocol.check()
        self.assertTrue(any('agents.brand_new' in p and 'neither route nor other' in p for p in problems))
        self.assertTrue(any('agents.brand_new' in p and 'GUI calls' in p for p in problems))

    def test_every_route_is_well_formed(self):
        data = protocol.load()
        self.assertEqual(data['protocol'], protocol.VERSION)
        for method, route in data['routes'].items():
            self.assertEqual(route['area'], method.split('.')[0], method)
            self.assertIn(route['kind'], ('read', 'preview', 'change', 'handle'), method)
            self.assertEqual(route['kind'] == 'handle', 'handle' in route, method)
            self.assertIn(route['source'], (None, 'observed', 'manual'), method)
            self.assertEqual(route['result'] is None, route['source'] is None, method)
            self.assertIsInstance(route['params'], dict, method)
        self.assertFalse(set(data['routes']) & set(data['other']))

    @unittest.skipUnless(shutil.which('unshare') and shutil.which('dart') or (ROOT / '.dart-sdk').exists(),
                         'needs unshare and the Dart SDK')
    def test_the_core_serves_every_route(self):
        data = protocol.load()
        names = sorted(m for m, r in data['routes'].items() if r['kind'] != 'handle')
        try:
            served = set(protocol.probe(names))
        except SystemExit as error:          # no user namespaces here: the probe needs one
            self.skipTest(str(error))
        self.assertEqual(sorted(set(names) - served), [])


if __name__ == '__main__':
    unittest.main()
