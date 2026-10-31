import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def listed(*files):
    done = subprocess.run([sys.executable, 'tools/test-changed', '--list', '--files', *files], cwd=ROOT,
                          capture_output=True, text=True, check=True)
    return done.stdout


class TestChanged(unittest.TestCase):
    def test_a_core_file_finds_the_parity_tests_of_its_dependents(self):
        found = listed('packages/maprisma_core/lib/src/desktop.dart')
        self.assertIn('core: dart analyze, dart test', found)
        self.assertIn('python test_dart_agent_actions_parity', found)
        self.assertIn('python test_dart_system_actions_parity', found)

    def test_the_router_runs_the_protocol_tests(self):
        found = listed('packages/maprisma_core/lib/src/core.dart')
        self.assertIn('python test_protocol', found)
        self.assertIn('python test_dart_worker_parity', found)

    def test_a_python_module_finds_its_unit_tests(self):
        self.assertIn('python test_agents', listed('agents.py'))

    def test_a_widget_finds_its_tests(self):
        found = listed('flutter_app/lib/app_theme.dart')
        self.assertIn('flutter test flutter_app/test/corners_test.dart', found)

    def test_shared_and_unknown_files_run_everything(self):
        self.assertIn('everything', listed('adapters/claude.toml'))
        self.assertIn('everything', listed('some/new/place.txt'))

    def test_docs_run_nothing(self):
        self.assertEqual(listed('docs/plan-flutter.md'), '')

    def test_manual_packaging_and_tools_run_their_tests(self):
        self.assertIn('python test_manual', listed('docs/manual/manual.html'))
        self.assertIn('python test_packaging', listed('packaging/unpack-adapters.py'))
        self.assertIn('python test_flutter_review_recheck', listed('tools/build-flutter-preview.py'))
        self.assertIn('python test_test_changed', listed('tools/test-changed'))
        self.assertIn('python test_i18n', listed('tools/flutter-assets.py'))
        self.assertIn('python test_manual', listed('data/user-manual.de.pdf'))
        self.assertNotIn('everything', listed('tools/flutter-assets.py', 'data/user-manual.de.pdf'))
