"""Development parity: skills from the web (skills_web) in the Python reference and the Dart core: a
skills.sh search answer, a GitHub file list turned into the files of one skill (links, submodules, paths
leaving the folder, too large, a repository that is one skill) and a SKILL.md's description. No
network. Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

SEARCH = {'skills': [
    {'name': 'PDF tools', 'skillId': 'pdf', 'source': 'anthropics/skills', 'installs': 1234},
    {'skillId': 'docx', 'source': 'anthropics/skills', 'installs': True},
    {'name': '', 'skillId': 'x' * 100, 'source': 'a/b', 'installs': '7'},
    {'skillId': 'bad id', 'source': 'a/b'}, {'skillId': 'ok', 'source': 'no-slash'},
    {'skillId': 'nl\n', 'source': 'a/b'}, {'skillId': 'ok', 'source': 'a/b\n'},
    {'skillId': 'n', 'source': 'a/b', 'name': 'N' * 150}, 'junk', None]}


def blob(path, size=10, mode='100644'):
    return {'path': path, 'type': 'blob', 'mode': mode, 'size': size}


TREES = [
    ({'tree': [blob('skills/pdf/SKILL.md'), blob('skills/pdf/scripts/run.py', mode='100755'),
               blob('skills/pdf/link', mode='120000'), {'path': 'skills/pdf/sub', 'type': 'commit', 'mode': '160000'},
               blob('skills/pdf/a/b/c/d/e/f/g/h/i.md'), blob('skills/pdf/bad\nname.md'), blob('skills/pdf/ok name.md'), blob('others/pdf/SKILL.md'), blob('nested/x/pdf/SKILL.md'),
               blob('skills/docx/SKILL.md'), {'path': 'skills/pdf', 'type': 'tree'}]}, 'pdf'),
    ({'tree': [blob('SKILL.md'), blob('README.md'), blob('src/tool.sh', mode='100755')]}, 'anything'),
    ({'tree': [blob('a/SKILL.md'), blob('a/huge.bin', size=6 * 1024 * 1024)]}, 'a'),
    ({'tree': [blob('a/SKILL.md')] + [blob(f'a/f{i}') for i in range(150)]}, 'a'),
    ({'tree': [blob('a/SKILL.md', size=None), blob('a/x')]}, 'a'),
    ({'tree': [blob('a/SKILL.md'), blob('a/x', size=True)]}, 'a'),
    ({'tree': [blob('a/README.md')]}, 'a'),
    ({'tree': 'nope'}, 'a'),
    ({'tree': [blob('a/b/SKILL.md'), blob('a/b/x.md', mode='100644')]}, 'b'),
]
TEXTS = ['---\nname: pdf\ndescription: Reads and writes PDFs.\n---\nbody',
         '---\nname: x\ndescription: >\n  Folded over\n  two lines\n\nother: 1\n---\n',
         "---\ndescription: '\"quoted\"'\n---", '---\ndescription: ' + 'long ' * 100 + '\n---',
         'no front matter', '---\nname: only\n---', '---\r\ndescription: crlf\r\n---\r\n',
         '---\ndescription: |\n\tTabbed\n  more\nnext: x\n---', '']

PYTHON = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import skills_web
task = json.loads(sys.stdin.read())
out = []
for tree, skill_id, text in task:
    try:
        folder, files = skills_web.files_of(tree, skill_id)
        files = [folder, [list(f) for f in files]]
    except ValueError as error:
        files = {'error': str(error)}
    out.append({'files': files, 'description': skills_web.description([('SKILL.md', text.encode(), False)])})
search = [{'name': s.name, 'skill_id': s.skill_id, 'repo': s.repo, 'installs': s.installs}
          for s in skills_web.parse_search(json.loads(sys.argv[2]))]
for item in out:
    item['search'] = search
print(json.dumps(out))
'''


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartSkillsWebParityTest(unittest.TestCase):
    def test_same_search_files_and_description(self):
        cases = [(tree, skill_id, TEXTS[i % len(TEXTS)]) for i, (tree, skill_id) in enumerate(TREES)]
        cases += [(TREES[0][0], 'pdf', text) for text in TEXTS]
        env = {**os.environ, 'LANG': 'C.UTF-8'}
        python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT), json.dumps(SEARCH)],
                                           input=json.dumps(cases), capture_output=True, check=True, text=True,
                                           env=env, timeout=120).stdout)
        lines = [json.dumps({'id': i, 'protocol': 2, 'method': 'dev.skillsweb',
                             'params': {'search': SEARCH, 'tree': tree, 'skill_id': skill_id, 'text': text}})
                 for i, (tree, skill_id, text) in enumerate(cases, 1)]
        out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                              'bin/fixture_probe.dart'], input=('\n'.join(lines) + '\n').encode(),
                             capture_output=True, cwd=ROOT / 'packages/maprisma_core', timeout=300, env=env)
        dart = [json.loads(line)['result'] for line in out.stdout.splitlines() if line.startswith(b'{')]
        self.maxDiff = None
        self.assertEqual(len(dart), len(cases), out.stderr.decode()[-2000:])
        self.assertEqual(python, dart)
        first = python[0]
        self.assertEqual([s['skill_id'] for s in first['search']], ['pdf', 'docx', 'x' * 100, 'n'])
        self.assertEqual(first['search'][1]['installs'], 0)
        self.assertEqual(first['files'][0], 'skills/pdf')
        self.assertEqual([f[0] for f in first['files'][1]], ['SKILL.md', 'scripts/run.py', 'ok name.md'])
        self.assertEqual(python[1]['files'][0], '')
        self.assertIn('error', python[2]['files'])
        self.assertIn('error', python[3]['files'])
        self.assertIn('error', python[5]['files'])
        self.assertEqual(python[len(TREES) + 1]['description'], 'Folded over two lines')


if __name__ == '__main__':
    unittest.main()
