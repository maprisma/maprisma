import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import agents
import connect
from flutter_backend import Service
from flutter_connections import Connections
import harnesses
import mcp_ctl
import skills_ctl


class ConnectionAuthoringTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.api = Connections(self.root / 'backups')
        self.catalog = [agents.Agent(c, c.title(), '', installed=True) for c in ('first', 'second')]
        self.configs = {c.command: self.root / f'{c.command}.json' for c in self.catalog}
        for path in self.configs.values():
            path.write_text('{"retained":"old-private-value"}')
        for patch in (
            mock.patch.object(agents, 'list_agents', return_value=self.catalog),
            mock.patch.object(mcp_ctl, 'supported', return_value=True),
            mock.patch.object(mcp_ctl, '_spec', side_effect=lambda c: harnesses.Mcp(path=str(self.configs[c]))),
            mock.patch.object(skills_ctl, 'HOME', self.root),
            mock.patch.object(connect, 'HOME', self.root),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        self.stdio = {'transport': 'stdio', 'command': '/never/executed/program',
                      'args': ['--argument', 'private-arg'], 'env': {'TOKEN': 'private-env'}, 'url': '', 'headers': {}}

    def request(self, **changes):
        return {'kind': 'mcp', 'agents': ['first'], 'name': 'new-server', 'entry': self.stdio, **changes}

    def test_mcp_creation_previews_private_counts_then_applies_and_undoes(self):
        with mock.patch('subprocess.Popen', side_effect=AssertionError('must not launch')):
            preview = self.api.author_preview(self.request(agents=['first', 'second']))
        self.assertEqual(preview['agents'], ['First', 'Second'])
        self.assertEqual(len(preview['files']), 2)
        for value in ('old-private-value', 'private-arg', 'private-env', self.stdio['command']):
            self.assertNotIn(value, json.dumps(preview))
        self.assertNotIn('mcpServers', self.configs['first'].read_text())
        applied = self.api.apply(preview['plan'])
        for path in self.configs.values():
            self.assertEqual(json.loads(path.read_text())['mcpServers']['new-server']['env']['TOKEN'], 'private-env')
        self.api.undo(applied['undo'])
        for path in self.configs.values():
            self.assertEqual(json.loads(path.read_text()), {'retained': 'old-private-value'})

    def test_remote_headers_and_url_secrets_never_reach_preview(self):
        entry = {'transport': 'http', 'command': '', 'args': [], 'env': {},
                 'url': 'https://user:secret@server.invalid/mcp?token=private-query',
                 'headers': {'Authorization': 'private-header'}}
        preview = self.api.author_preview(self.request(entry=entry))
        for secret in ('private-query', 'private-header', 'https://user:secret'):
            self.assertNotIn(secret, json.dumps(preview))
        self.api.apply(preview['plan'])
        self.assertEqual(json.loads(self.configs['first'].read_text())['mcpServers']['new-server']['headers'], entry['headers'])

    def test_existing_definition_has_replacement_disclosure(self):
        self.api.apply(self.api.author_preview(self.request())['plan'])
        preview = self.api.author_preview(self.request(entry={**self.stdio, 'args': ['changed']}))
        self.assertTrue(any('replaced' in note for note in preview['notes']))

    def test_unknown_agents_duplicates_or_fields_are_rejected_before_planning(self):
        for fields in ({'agents': []}, {'agents': ['missing']}, {'agents': ['first', 'first']},
                       {'agents': ['first'] * 33}, {'name': '../outside'}, {'name': 'bad\n'}, {'path': '/anywhere'}):
            with self.subTest(fields=fields), mock.patch.object(mcp_ctl, 'plan') as plan:
                with self.assertRaises(ValueError):
                    self.api.author_preview(self.request(**fields))
                plan.assert_not_called()

    def test_invalid_or_oversized_fields_are_rejected(self):
        bad = [{'args': 'shell text'}, {'args': ['x'] * 129}, {'command': 'x\x00'},
               {'env': {'BAD\n': 'x'}}, {'headers': {'Authorization': 'x\r\ny'}},
               {'env': {'TOKEN': 'x' * 8193}}, {'transport': 'file'}, {'url': 'https://x\n.invalid'},
               {'args': [None]}, {'command': 'x\ry'}]
        for changes in bad:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.api.author_preview(self.request(entry={**self.stdio, **changes}))

    def test_source_folder_is_explicit_bounded_and_metadata_only(self):
        folder = self.root / 'sources'
        (folder / 'example').mkdir(parents=True)
        (folder / 'example/SKILL.md').write_text('private-instructions-are-not-read')
        own = self.root / 'agent-skills'
        with mock.patch.object(skills_ctl, 'own_dir', return_value=str(own)), \
                mock.patch.object(skills_ctl, 'native_dirs', return_value=[]), \
                mock.patch.object(skills_ctl, 'config_dirs', return_value=[]):
            preview = self.api.author_preview({'kind': 'skills', 'agents': ['first'], 'folder': str(folder)})
        self.assertNotIn('private-instructions', json.dumps(preview))
        self.assertEqual(len(preview['links_add']), 1)
        self.assertFalse(own.exists())
        result = self.api.apply(preview['plan'])
        self.assertTrue((own / 'example').is_symlink())
        self.api.undo(result['undo'])
        self.assertFalse((own / 'example').exists())
        self.assertTrue((folder / 'example/SKILL.md').exists())

    def test_empty_relative_and_oversized_folders_are_rejected(self):
        empty = self.root / 'empty'
        empty.mkdir()
        for folder in (str(empty), 'relative'):
            with self.subTest(folder=folder), self.assertRaises(ValueError):
                self.api.author_preview({'kind': 'skills', 'agents': ['first'], 'folder': folder})
        for index in range(201):
            (empty / f'entry-{index}').touch()
        with self.assertRaises(ValueError):
            self.api.author_preview({'kind': 'skills', 'agents': ['first'], 'folder': str(empty)})

    def test_conflicting_links_and_more_than_200_links_rejected_and_duplicates_merged(self):
        link, source = self.root / 'link', self.root / 'source'
        plan = connect.Plan('', '', '', links_add=[(link, source), (link, source)])
        self.assertEqual(len(self.api.keep(plan)['links_add']), 1)
        with self.assertRaises(ValueError):
            self.api.keep(connect.Plan('', '', '', links_add=[(link, source), (link, self.root / 'other')]))
        with self.assertRaises(ValueError):
            self.api.keep(connect.Plan('', '', '', links_add=[(self.root / str(i), source) for i in range(201)]))

    def test_author_preview_dispatch_uses_only_known_graph_ids(self):
        service = Service.__new__(Service)
        service.tasks = mock.Mock()
        service.adapters = None
        service.connections = self.api
        service._map_result = {'nodes': [{'id': 'agent:first'}, {'id': 'mcp:new-server'}], 'edges': []}
        reply = service.dispatch('connections.author_preview', self.request())
        self.assertEqual(reply['focus'], ['agent:first', 'mcp:new-server'])
        self.assertNotIn('agent_commands', reply)
        self.assertNotIn('private-env', json.dumps(reply))

    def test_native_skill_access_is_explained_and_not_modified(self):
        folder = self.root / 'native'
        (folder / 'example').mkdir(parents=True)
        (folder / 'example/SKILL.md').write_text('skill')
        with mock.patch.object(skills_ctl, 'own_dir', return_value=str(folder)), \
                mock.patch.object(skills_ctl, 'native_dirs', return_value=[str(folder)]), \
                mock.patch.object(skills_ctl, 'config_dirs', return_value=[]):
            result = self.api.author_preview({'kind': 'skills', 'agents': ['first'], 'folder': str(folder)})
        self.assertTrue(result['empty'])
        self.assertTrue(any('automatically' in note for note in result['notes']))
        self.assertEqual(result['links_add'], [])
