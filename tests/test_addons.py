import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import addon_api  # noqa: E402
import addons  # noqa: E402
import edition  # noqa: E402

GOOD = '''
CALLS = []

def register(api):
    api.add_help_card(lambda ui, box: CALLS.append("help"))
    api.add_details_section(lambda ui, box, harness, sessions, since: None, 2)
    api.add_session_titles("opencode", lambda: {"a": "A title"})
'''


@unittest.skipUnless(shutil.which("ssh-keygen"), "needs OpenSSH's ssh-keygen")
class AddonsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys = tempfile.TemporaryDirectory()
        cls.key = Path(cls.keys.name) / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "test", "-f", str(cls.key)], check=True)
        cls.signers = f'{addons.PRINCIPAL} namespaces="{addons.NAMESPACE}" ' + \
            " ".join(cls.key.with_suffix(".pub").read_text().split()[:2])

    @classmethod
    def tearDownClass(cls):
        cls.keys.cleanup()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "addons"
        self.root.mkdir(mode=0o755)
        self.hooks = addon_api.Hooks()

    def build(self, addon_id="insights", code=GOOD, meta=None, extra=None, sign=True):
        folder = self.root / addon_id
        (folder / "translations").mkdir(parents=True)
        info = {"id": addon_id, "name": "Insights", "version": "1.0.0", "api": addon_api.API_VERSION,
                "privacy": "titles", "harnesses": ["opencode"], "reads": ["OpenCode's session titles"],
                "sends": []}
        info.update(meta or {})
        files = {"addon.json": json.dumps(info), "addon.py": code,
                 "translations/de.json": json.dumps({"Topics": "Themen"}), **(extra or {})}
        if code is None:                                   # a data-only add-on (agent.toml)
            del files["addon.py"]
        for name, text in files.items():
            (folder / name).write_text(text)
        manifest = "".join(f"{hashlib.sha256((folder / n).read_bytes()).hexdigest()}  {n}\n" for n in sorted(files))
        (folder / "MANIFEST.sha256").write_text(manifest)
        if sign:
            subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(self.key), "-n", addons.NAMESPACE,
                            str(folder / "MANIFEST.sha256")], check=True, capture_output=True)
            (folder / "MANIFEST.sha256.sig").rename(folder / "SIGNATURE")
        for path in folder.rglob("*"):
            path.chmod(0o755 if path.is_dir() else 0o644)
        folder.chmod(0o755)
        return folder

    def verify(self, folder):
        return addons.verify(folder, self.signers)

    def test_a_signed_addon_verifies_and_loads(self):
        addon = self.verify(self.build())
        self.assertEqual((addon.state, addon.reason), ("verified", ""))
        self.assertEqual((addon.name, addon.version, addon.privacy), ("Insights", "1.0.0", edition.TITLES))
        self.assertEqual(addon.reads, ["OpenCode's session titles"])
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "loaded")
        self.assertEqual([h[0] for h in self.hooks.help], ["insights"])
        self.assertEqual(self.hooks.privacy, {"insights": edition.TITLES})
        api = addon_api.AddonAPI("other", edition.NUMBERS, hooks=self.hooks)
        self.assertEqual(api.session_titles("opencode"), {"a": "A title"})

    def agent_addon(self, toml_text, meta=None):
        gemini = (Path(__file__).resolve().parent.parent / "adapters/gemini.toml").read_text()
        gemini = gemini.replace('command = "gemini"', 'command = "gemini-test"')   # not the built-in one
        return self.build("agent-gemini", code=None, extra={"agent.toml": toml_text if toml_text else gemini},
                          meta={"kind": "agent", "capabilities": ["agent"], "provides": ["gemini-test"],
                                "privacy": "numbers", **(meta or {})})

    def test_a_data_only_agent_addon_brings_no_code(self):
        import harnesses
        addon = self.verify(self.agent_addon(None))
        self.assertEqual((addon.state, addon.brings_code), ("verified", False))
        addons.load(addon, self.hooks)
        self.addCleanup(harnesses.remove_added, "agent-gemini")
        self.assertEqual((addon.state, addon.reason), ("loaded", ""))
        self.assertIn("gemini-test", [h.command for _id, h in harnesses._ADDED])

    def test_a_broken_agent_toml_fails_with_its_reason(self):
        addon = self.verify(self.agent_addon('command = "gemini"\nname = "Gemini"\nhomepgae = "x"\n'))
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("homepgae", addon.reason)

    def test_agent_toml_only_in_an_agent_addon(self):
        addon = self.verify(self.agent_addon(None, meta={"kind": "feature"}))
        self.assertEqual((addon.state, addon.reason), ("refused", "agent.toml belongs only in an agent add-on"))

    def test_hooks_only_beside_an_agent_toml(self):
        folder = self.build("agent-x", code="def register(api):\n    pass\n", extra={"hooks.py": "x = 1\n"},
                            meta={"kind": "agent", "capabilities": ["agent"], "privacy": "numbers"})
        addon = self.verify(folder)
        self.assertEqual((addon.state, addon.reason), ("refused", "hooks.py belongs beside an agent.toml"))

    def test_capabilities_still_apply_to_facts(self):
        claude = (Path(__file__).resolve().parent.parent / "adapters/claude.toml").read_text()
        claude = claude.replace('command = "claude"', 'command = "gemini-test"')
        claude = claude.replace('argv = ["claude", "-p"', 'argv = ["gemini-test", "-p"')   # its ask command too
        claude = claude.replace('argv = ["claude", "doctor"]', 'argv = ["gemini-test", "doctor"]')   # and Configure
        claude = claude.replace('argv = ["claude", "{prompt}"]', 'argv = ["gemini-test", "{prompt}"]')   # and its task
        addon = self.verify(self.agent_addon(claude))
        addons.load(addon, self.hooks)                     # it has an updater, but no "updater" capability
        self.assertEqual(addon.state, "failed")
        self.assertIn("updater", addon.reason)

    def test_only_uwes_key(self):
        addon = addons.verify(self.build())          # the built-in key, not the test key
        self.assertEqual((addon.state, addon.reason), ("refused", "not signed by Uwe Bruckhaus"))
        self.assertEqual(addon.files, {})

    def test_unsigned(self):
        self.assertEqual(self.verify(self.build(sign=False)).reason, "not signed")

    def test_changed_file(self):
        folder = self.build()
        with open(folder / "addon.py", "a") as handle:
            handle.write("\nimport os\n")
        self.assertEqual(self.verify(folder).reason, "addon.py was changed")

    def test_added_file(self):
        folder = self.build()
        (folder / "translations/fr.json").write_text("{}")
        (folder / "translations/fr.json").chmod(0o644)
        self.assertEqual(self.verify(folder).reason, "files differ from the signed list")

    def test_unexpected_file_kind(self):
        folder = self.build(extra={"helper.py": "x = 1"})
        self.assertEqual(self.verify(folder).reason, "unexpected file helper.py")

    def test_link(self):
        folder = self.build()
        (folder / "addon.py").rename(folder / "real.py")
        (folder / "addon.py").symlink_to(folder / "real.py")
        self.assertIn("link", self.verify(folder).reason)

    def test_writable_by_others(self):
        folder = self.build()
        (folder / "addon.py").chmod(0o666)
        self.assertEqual(self.verify(folder).reason, "addon.py cannot be read safely")
        (folder / "addon.py").chmod(0o644)
        folder.chmod(0o775)
        self.assertIn("writable by others", self.verify(folder).reason)

    def test_wrong_api(self):
        addon = self.verify(self.build(meta={"api": 99}))
        self.assertIn("API 99", addon.reason)

    def test_id_must_match_folder(self):
        self.assertEqual(self.verify(self.build(meta={"id": "other"})).reason,
                         "addon.json does not name this add-on")

    def test_nothing_runs_while_verifying(self):
        folder = self.build(code="raise SystemExit('ran')\n")
        self.assertEqual(self.verify(folder).state, "verified")

    def test_more_than_declared_privacy_fails_cleanly(self):
        code = "def register(api):\n    api.add_help_card(lambda ui, box: None)\n    api.add_session_titles('x', dict)\n"
        addon = addons.load(self.verify(self.build(code=code, meta={"privacy": "numbers"})), self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("privacy", addon.reason)
        self.assertEqual(self.hooks.help, [])                     # its earlier hooks are taken back
        self.assertEqual(self.hooks.privacy, {})

    def test_broken_register_fails_cleanly(self):
        addon = addons.load(self.verify(self.build(code="def register(api):\n    1 / 0\n")), self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("ZeroDivisionError", addon.reason)

    def test_runs_from_verified_bytes(self):
        folder = self.build()
        addon = self.verify(folder)
        (folder / "addon.py").write_text("def register(api):\n    raise RuntimeError('swapped')\n")
        self.assertEqual(addons.load(addon, self.hooks).state, "loaded")

    def test_load_all_only_loads_switched_on(self):
        self.build()
        found = addons.load_all(set(), dirs=(self.root,), signers=self.signers, hooks=self.hooks)
        self.assertEqual([a.state for a in found], ["verified"])
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers, hooks=self.hooks)
        self.assertEqual([a.state for a in found], ["loaded"])

    def test_user_folder_wins(self):
        self.build()
        system = self.root.parent / "system"
        system.mkdir()
        (system / "insights").mkdir()
        self.assertEqual(addons.find((self.root, system)), [self.root / "insights"])

    def test_translations(self):
        api = addon_api.AddonAPI("insights", edition.TITLES, addons.strings(self.verify(self.build())))
        with mock.patch("i18n.current", return_value="de"):
            self.assertEqual(api.tr("Topics"), "Themen")
            self.assertEqual(api.tr("Other"), "Other")

    def test_without_ssh_keygen(self):
        folder = self.build()
        with mock.patch("shutil.which", return_value=None):
            self.assertIn("ssh-keygen", self.verify(folder).reason)

    def test_edition_follows_loaded_addons(self):
        self.addCleanup(addon_api.HOOKS.clear)
        addon_api.HOOKS.clear()
        self.assertEqual(edition.maximum(), edition.NUMBERS)
        addons.load(self.verify(self.build()))
        self.assertEqual(edition.maximum(), edition.TITLES)


    # --- add-ons that bring agents and providers ---

    AGENT_AND_LLM = """
def register(api):
    api.add_harness(api.Harness("demo-agent", "Demo agent", label="Demo agent", icon="D", offered=False,
                                detect=lambda: (True, "0.1", "own")))

    def detect(processes):
        return api.Runtime("demo-llm", "Demo LLM", installed=True, address="127.0.0.1:9999")
    api.add_provider(api.Provider("demo-llm", "Demo LLM", "local", detect=detect, connect_key="demo-local",
                                  connect_label="Demo LLM (local)"))
"""

    def registries_reset(self):
        import harnesses
        import providers
        self.addCleanup(lambda: (harnesses.remove_added(), providers.remove_added(), harnesses.changed(),
                                 providers.changed(), addon_api.HOOKS.clear()))

    def test_addon_brings_an_agent_and_a_local_llm(self):
        import agents
        import connect
        import graph
        import harnesses
        import inventory
        import providers
        self.registries_reset()
        self.build(code=self.AGENT_AND_LLM, meta={"privacy": "numbers", "capabilities": ["agent", "provider"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertEqual([a.state for a in found], ["loaded"])
        self.assertEqual(harnesses.get("demo-agent").name, "Demo agent")
        self.assertIn("demo-agent", [c for c, *_r in agents.EXTRA])
        self.assertEqual(agents.detect("demo-agent"), (True, "0.1", "own"))
        self.assertEqual(connect.KEYS["demo-llm"], "demo-local")
        with mock.patch.object(inventory, "own_processes", return_value=[]):
            inv = inventory.collect([])
        self.assertIn("demo-llm", [rt.key for rt in inv.runtimes])
        nodes = graph.build([], {}, inv).nodes
        self.assertIn("Demo LLM", [n.label for n in nodes])
        # Switched off: gone everywhere.
        addons.load_all(set(), dirs=(self.root,), signers=self.signers)
        self.assertIsNone(harnesses.get("demo-agent"))
        self.assertNotIn("demo-agent", [c for c, *_r in agents.EXTRA])
        self.assertNotIn("demo-llm", connect.KEYS)
        self.assertIsNone(providers.get("demo-llm"))

    def test_agents_need_the_capability(self):
        import harnesses
        self.registries_reset()
        self.build(code=self.AGENT_AND_LLM, meta={"privacy": "numbers", "capabilities": ["provider"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertEqual(found[0].state, "failed")
        self.assertIn('"agent"', found[0].reason)
        self.assertIsNone(harnesses.get("demo-agent"))

    def test_built_in_ids_cannot_be_replaced(self):
        import providers
        self.registries_reset()
        code = """
def register(api):
    api.add_provider(api.Provider("ollama", "Fake Ollama", "local"))
"""
        self.build(code=code, meta={"privacy": "numbers", "capabilities": ["provider"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertEqual(found[0].state, "failed")
        self.assertIn("exists already", found[0].reason)
        self.assertEqual(providers.get("ollama").name, "Ollama")

    def test_its_own_icon(self):
        import icons
        svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16z"/></svg>'
        self.build(extra={"icon.svg": svg})
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(icons, "ADDON_DIR", Path(tmp)):
            found = addons.load_all(set(), dirs=(self.root,), signers=self.signers)
            self.assertEqual((found[0].state, found[0].icon), ("verified", "am-addon-insights-symbolic"))
            self.assertTrue((Path(tmp) / "am-addon-insights-symbolic.svg").is_file())

    def test_an_icon_that_could_load_anything_is_refused(self):
        self.build(extra={"icon.svg": '<svg><image href="https://x/y.png"/></svg>'})
        self.assertIn("icon.svg may only hold shapes", self.verify(self.root / "insights").reason)

    def test_declared_commands_must_be_plain_words(self):
        self.registries_reset()
        code = """
def register(api):
    api.add_harness(api.Harness("plainx", "Plain X", install=(api.Way("command", argv=("sh", "-c", "curl x | sh")),)))
"""
        self.build(code=code, meta={"privacy": "numbers", "capabilities": ["agent"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertIn("only plain words", found[0].reason)

    def test_a_download_needs_the_installer_capability_and_good_data(self):
        self.registries_reset()
        code = """
def register(api):
    api.add_harness(api.Harness("dl", "DL", download=api.Download(repo="acme/dl", assets=(("", "dl-x64"),),
                                                                   binary="dl", command="dl", single_file=True)))
"""
        self.build(code=code, meta={"privacy": "numbers", "capabilities": ["agent"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertIn("installer", found[0].reason)
        self.registries_reset()
        bad = code.replace('binary="dl"', 'binary="../dl"')
        self.build(addon_id="bad", code=bad, meta={"id": "bad", "privacy": "numbers", "capabilities": ["agent", "installer"]})
        found = {a.id: a for a in addons.load_all({"bad"}, dirs=(self.root,), signers=self.signers)}
        self.assertIn("download", found["bad"].reason)

    def test_an_updater_with_its_capability_is_allowed(self):
        self.registries_reset()
        code = """
def register(api):
    api.add_harness(api.Harness("upd2", "Upd", self_update=("upd2", "update")))
"""
        self.build(code=code, meta={"privacy": "numbers", "capabilities": ["agent", "updater"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertEqual(found[0].state, "loaded", found[0].reason)
        import agent_updates
        self.assertTrue(agent_updates._allowed(["upd2", "update"]))
        import harnesses
        harnesses.remove_added()
        self.assertFalse(agent_updates._allowed(["upd2", "update"]))

    def test_no_updater_and_no_unknown_capabilities(self):
        self.registries_reset()
        code = """
def register(api):
    api.add_harness(api.Harness("upd", "Upd", self_update=("upd", "update"), latest=lambda c: "9"))
"""
        self.build(code=code, meta={"privacy": "numbers", "capabilities": ["agent"]})
        found = addons.load_all({"insights"}, dirs=(self.root,), signers=self.signers)
        self.assertIn("updater", found[0].reason)
        import agent_updates
        self.assertEqual(agent_updates.self_updates(), (["claude", "update"],))   # refused: nothing added
        self.assertEqual(self.verify(self.build(addon_id="other", meta={"id": "other", "capabilities": ["root"]})).reason,
                         "unknown capabilities")


class HookCallTest(unittest.TestCase):
    def test_failing_callback_is_noted_not_raised(self):
        hooks = addon_api.Hooks()
        with mock.patch.object(addon_api, "HOOKS", hooks):
            self.assertIsNone(addon_api.call("x", lambda: 1 / 0))
            self.assertIn("ZeroDivisionError", hooks.errors["x"])


EXTENSION = '''
def register(api):
    api.extend_harness("opencode", limits=lambda: ("Plan X", []))
    api.add_details_section(lambda ui, box, harness, sessions, since: None, card="statistics")
'''


@unittest.skipUnless(shutil.which("ssh-keygen"), "needs OpenSSH's ssh-keygen")
class ExtensionAddonTest(AddonsTest):
    """An extension add-on adds facts to an agent another add-on (or the app) brings."""

    def tearDown(self):
        import harnesses
        harnesses.remove_added()

    def ext(self, code=EXTENSION, meta=None):
        info = {"kind": "extension", "extends": ["opencode"], "privacy": "numbers"}
        info.update(meta or {})
        return self.verify(self.build("ext-limits", code, info))

    def test_it_fills_an_empty_fact_and_names_its_card(self):
        import harnesses
        addon = self.ext()
        self.assertEqual((addon.state, addon.kind, addon.extends), ("verified", "extension", ["opencode"]))
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "loaded", addon.reason)
        self.assertEqual(harnesses.get("opencode").limits(), ("Plan X", []))
        self.assertEqual([h[3] for h in self.hooks.details], ["statistics"])

    def test_without_extends_it_is_refused(self):
        self.assertEqual(self.ext(meta={"extends": []}).reason, "an extension names no agent in \"extends\"")

    def test_only_the_agents_it_names(self):
        addon = self.ext(code='''
def register(api):
    api.extend_harness("claude", limits=lambda: ("x", []))
''')
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("not in", addon.reason)

    def test_never_what_installs_or_updates(self):
        addon = self.ext(code='''
def register(api):
    api.extend_harness("opencode", installer=lambda: None)
''')
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("cannot extend installer", addon.reason)

    def test_it_extends_a_provider_and_its_page(self):
        import providers
        addon = self.ext(code='''
def register(api):
    api.extend_provider("llamacpp", usage=lambda rt: None)
    api.add_details_section(lambda ui, box, provider, runtime: None, card="health", page="llm")
''', meta={"extends": ["llamacpp"]})
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "loaded", addon.reason)
        self.assertIsNotNone(providers.get("llamacpp").usage)
        self.assertEqual([(h[3], h[4]) for h in self.hooks.details], [("health", "llm")])
        providers.remove_added()

    def test_no_topics_on_llm_pages(self):
        addon = self.ext(code='''
def register(api):
    api.add_details_section(lambda ui, box, provider, runtime: None, card="topics", page="llm")
''')
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("agents' pages only", addon.reason)

    def test_a_feature_addon_cannot_extend(self):
        addon = self.verify(self.build(code=EXTENSION, meta={"privacy": "numbers"}))
        addons.load(addon, self.hooks)
        self.assertEqual(addon.state, "failed")
        self.assertIn("kind", addon.reason)


if __name__ == "__main__":
    unittest.main()
