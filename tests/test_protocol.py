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
        gui = protocol.gui_names() | {'agents.brand_new'}
        names = protocol.core_names() | {'agents.brand_new'}
        with mock.patch.object(protocol, 'gui_names', return_value=gui), \
                mock.patch.object(protocol, 'core_names', return_value=names):
            problems = protocol.check()
        self.assertTrue(any('agents.brand_new' in p and 'neither route nor other' in p for p in problems))
        self.assertTrue(any('agents.brand_new' in p and 'GUI calls' in p for p in problems))

    def test_a_renamed_route_left_in_the_gui_is_caught(self):
        from unittest import mock
        data = protocol.load()
        data['routes']['found.rescan'] = data['routes'].pop('found.scan')
        core = (protocol.core_names() - {'found.scan'}) | {'found.rescan'}
        dispatch = (protocol.dispatch_names() - {'found.scan'}) | {'found.rescan'}
        doc = protocol.DOC.read_text()[:-1]
        client = protocol.CLIENT.read_text()[:-1]
        with mock.patch.object(protocol, 'load', return_value=data), \
                mock.patch.object(protocol, 'core_names', return_value=core), \
                mock.patch.object(protocol, 'dispatch_names', return_value=dispatch), \
                mock.patch.object(protocol, 'doc_text', return_value=doc), \
                mock.patch.object(protocol, 'client_text', return_value=client):
            problems = protocol.check()
        self.assertEqual(problems, ["the GUI calls routes the contract does not have: ['found.scan']"])

    def test_a_literal_gui_call_or_stale_client_is_caught(self):
        from unittest import mock
        with mock.patch.object(protocol, 'gui_calls', return_value={'agents.details': {'command': '?'}}):
            problems = protocol.check()
        self.assertTrue(any('agents.details' in p and 'CoreClient' in p for p in problems))
        with mock.patch.object(protocol, 'client_text', return_value='// stale'):
            problems = protocol.check()
        self.assertTrue(any('core_client.g.dart is not up to date' in p for p in problems))

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
