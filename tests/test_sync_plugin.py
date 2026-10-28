import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools/sync-plugin.py"


def load_tool():
    spec = importlib.util.spec_from_file_location("sync_plugin", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(TOOL.is_file(), "tools/ is part of Asterism only (the plugin is made from it)")
class SyncPluginTest(unittest.TestCase):
    """One source for both editions: the plugin's shared files are made from this tree."""

    def setUp(self):
        self.tool = load_tool()
        self.tmp = tempfile.TemporaryDirectory()
        self.plugin = Path(self.tmp.name)
        own = {"manifest.json": "{}", "BarWidget.qml": "Item {}", "I18n.js": "//", "README.md": "plugin",
               "ai-agents-map-toggle": "# LOCAL ONLY", "assets/drawing-demo.gif": "gif"}
        for rel, text in own.items():
            (self.plugin / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.plugin / rel).write_text(text)
        self.own = own

    def tearDown(self):
        self.tmp.cleanup()

    def run_quietly(self, function):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return function(self.plugin)

    def test_sync_copies_shared_keeps_own_removes_stale(self):
        (self.plugin / "gone_module.py").write_text("# removed in Asterism")
        self.assertEqual(self.run_quietly(self.tool.check), 1)
        self.run_quietly(self.tool.sync)
        self.assertEqual(self.run_quietly(self.tool.check), 0)
        self.assertFalse((self.plugin / "gone_module.py").exists())
        self.assertTrue((self.plugin / "ai_popup.py").is_file())
        self.assertTrue((self.plugin / "translations/de.json").is_file())
        self.assertTrue((self.plugin / "assets/user-manual.pdf").is_file())
        for rel, text in self.own.items():                       # the plugin's own files untouched
            self.assertEqual((self.plugin / rel).read_text(), text, rel)

    def test_addon_modules_and_their_tests_stay_out(self):
        files = self.tool.wanted()
        for name in self.tool.ASTERISM_ONLY:
            self.assertNotIn(name, files)
            self.assertNotIn(f"tests/test_{name}", files)
        for rel in files:
            if rel.startswith("tests/") and rel.endswith(".py"):
                self.assertIsNone(self.tool.ADDON_IMPORT.search(files[rel].read_text()), rel)

    def test_an_edit_in_the_plugin_is_found(self):
        self.run_quietly(self.tool.sync)
        with open(self.plugin / "graph.py", "a") as handle:
            handle.write("# edited in the plugin\n")
        self.assertEqual(self.run_quietly(self.tool.check), 1)

    def test_thin_launchers_are_refused_before_sync(self):
        for manifest, marker in (("{\"id\":\"ubruckhaus.asterism\"}", False),
                                 ("{\"id\":\"ubruckhaus.ai-agents-map\"}", True)):
            (self.plugin / "manifest.json").write_text(manifest)
            if marker:
                (self.plugin / "THIN_LAUNCHER").touch()
            with self.assertRaises(SystemExit):
                self.tool.refuse_thin_launcher(self.plugin)
            self.assertFalse((self.plugin / "ai_popup.py").exists())


    def test_flutter_service_and_tests_are_excluded(self):
        files = self.tool.wanted()
        for rel in files:
            self.assertFalse(Path(rel).name.startswith(('flutter_', 'test_flutter_')), rel)
        self.assertNotIn('terminal_sessions.py', files)
        self.assertNotIn('tests/test_terminal_sessions.py', files)
