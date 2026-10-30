"""Development parity: an agent's last 30 days per project folder (claude_sessions.projects, subagents,
busiest, and the texts of details_pages.fill_session_projects) in the Python reference and the Dart core:
sessions older than 30 days left out, an unknown folder, subagent runs in a project's tokens, lines
changed and an API value, a tie in working time, the busiest hour, plurals, in English and German.
Skipped without a native Dart SDK."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tools'))
try:
    from dart_sdk import resolve_dart
    DART = resolve_dart()
except (OSError, ValueError, RuntimeError):
    DART = None

PYTHON = r'''
import json, sys
sys.path.insert(0, sys.argv[1])
import claude_sessions
from i18n import _, ngettext
from reference_texts import duration_text, short_number
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
case = json.loads(sys.stdin.read())
sessions = [claude_sessions.Session(**d) for d in case['sessions']]
since = case['now'] - 30 * 86400
rows = claude_sessions.projects(sessions, since)
tilde = lambda p: '~' + p[len('/home/u'):] if p.startswith('/home/u/') else p
card = None
if rows:
    summary = " · ".join([ngettext("1 project", "{0} projects", len(rows)).format(len(rows)),
                          _("{0} tokens").format(short_number(sum(r.tokens for r in rows))),
                          _("{0} working").format(duration_text(sum(r.active for r in rows)))])
    projects = []
    for project in rows[:10]:
        parts = [_("{0} working").format(duration_text(project.active)),
                 ngettext("1 session", "{0} sessions", project.sessions).format(project.sessions),
                 _("{0} tokens").format(short_number(project.tokens))]
        if project.subagent_runs:
            parts.append(ngettext("1 subagent run", "{0} subagent runs", project.subagent_runs).format(project.subagent_runs))
        if project.lines_added or project.lines_removed:
            parts.append(_("+{0} −{1} lines").format(project.lines_added, project.lines_removed))
        if project.cost:
            parts.append(_("API value {0}").format(f"$ {project.cost:.2f}"))
        projects.append({'folder': tilde(project.cwd) if project.cwd != "?" else _("Unknown folder"),
                         'text': " · ".join(parts)})
    runs = claude_sessions.subagents(sessions, since)
    card = {'title': _("Projects, last 30 days"), 'summary': summary, 'projects': projects}
    if runs:
        card['subagents_title'] = _("Subagents, last 30 days")
    card['subagents'] = [{'kind': kind if kind != "?" else _("Unknown type"),
                          'text': " · ".join((ngettext("1 run", "{0} runs", count).format(count),
                                              _("{0} tokens").format(short_number(tokens)),
                                              _("{0} working").format(duration_text(active))))}
                         for kind, count, tokens, active in runs[:10]]
    peak = claude_sessions.busiest(sessions, since)
    notes = []
    if peak is not None:
        notes.append(_("Most active: {0}, around {1}:00").format(_(WEEKDAYS[peak[0]]), peak[1]))
    if case['note']:
        notes.append(case['note'])
    card['notes'] = notes
print(json.dumps({'card': card}))
'''


def session(cwd, last, active, tokens, **more):
    return {'cwd': cwd, 'first': last - active, 'last': last, 'active': active, 'replies': 3,
            'tokens': tokens, 'hours': more.pop('hours', {}), 'lines_added': more.pop('added', 0),
            'lines_removed': more.pop('removed', 0), 'cost': more.pop('cost', 0.0), 'api_ms': 0,
            'subagents': more.pop('subagents', {})}


@unittest.skipIf(DART is None, 'native Dart SDK not available')
class DartProjectsParityTest(unittest.TestCase):
    def test_same_projects(self):
        now = 1_793_300_000.0
        sessions = [
            session('/home/u/work/a', now - 3600, 5400.0, {'claude-opus-5-5': [100, 2000, 50000, 300]},
                    hours={'61': 4, '62': 2}, added=120, removed=7, cost=3.455,
                    subagents={'Explore': [2, 4000, 300.0], '?': [1, 100, 30.0]}),
            session('/home/u/work/a', now - 86400, 60.0, {'claude-opus-5-5': [1, 1, 1, 1]}, hours={'61': 1}),
            session('/home/u/work/b', now - 7200, 5400.0, {'gpt-6-sol': [10, 20, 30, 40]}, hours={'15': 5}),
            session('', now - 7200, 30.0, {'x': [1, 0, 0, 0]}),
            session('/home/u/old', now - 40 * 86400, 9000.0, {'x': [999, 0, 0, 0]}),
        ]
        note = "Numbers from Claude Code's session files (no text is read)."
        for lang in ('en', 'de'):
            with self.subTest(lang=lang), tempfile.TemporaryDirectory() as temp:
                home = Path(temp)
                (home / '.config/ai-agents-map').mkdir(parents=True)
                (home / '.config/ai-agents-map/settings.json').write_text(json.dumps({'language': lang}))
                (home / '.config/maprisma').mkdir(parents=True)
                (home / '.config/maprisma/settings.json').write_text(json.dumps({'language': lang}))
                case = {'sessions': sessions, 'now': now, 'note': note}
                env = {k: v for k, v in os.environ.items() if not k.startswith('XDG_')}
                env.update(HOME=str(home), LANG='de_DE.UTF-8' if lang == 'de' else 'C.UTF-8', TZ='Europe/Berlin', ASTERISM_DESKTOP='generic')
                python = json.loads(subprocess.run([sys.executable, '-c', PYTHON, str(ROOT)],
                                                   input=json.dumps(case), capture_output=True, check=True,
                                                   text=True, env=env, timeout=60).stdout)
                line = json.dumps({'id': 1, 'protocol': 1, 'method': 'dev.projects', 'params': case})
                out = subprocess.run([DART, '--disable-dart-dev', '--packages=.dart_tool/package_config.json',
                                      'bin/fixture_probe.dart'], input=(line + '\n').encode(), capture_output=True,
                                     cwd=ROOT / 'packages/asterism_core', timeout=300, env=env)
                dart = [json.loads(x) for x in out.stdout.splitlines() if x.startswith(b'{')]
                self.assertEqual(len(dart), 1, out.stderr.decode()[-2000:])
                self.assertIn('result', dart[0], dart[0])
                self.maxDiff = None
                self.assertEqual(python, dart[0]['result'])
                if lang == 'en':
                    card = python['card']
                    self.assertEqual(card['summary'], '3 projects · 6.6k tokens · 3 h 1 min working')
                    self.assertEqual(card['projects'][0]['folder'], '~/work/a')
                    self.assertIn('API value $ 3.46', card['projects'][0]['text'])
                    self.assertEqual(card['notes'][0], 'Most active: Wednesday, around 13:00')
                else:
                    self.assertTrue(python['card']['title'].startswith('Projekte'))


if __name__ == '__main__':
    unittest.main()
