"""The adapters as add-ons (tools/build-adapter-addons.py): signed and loaded with the built-ins off,
the registries hold the same agents and providers, in the same order, as with the built-ins."""

import dataclasses
import hashlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import addon_api  # noqa: E402
import addons  # noqa: E402
import harnesses  # noqa: E402
import providers  # noqa: E402


def same(a, b) -> list:
    """Fields that differ (functions compared by name: the add-on has its own copies)."""
    out = []
    for f in dataclasses.fields(a):
        x, y = getattr(a, f.name), getattr(b, f.name)
        if callable(x) and callable(y):
            x, y = x.__name__, y.__name__
        elif isinstance(x, tuple) and isinstance(y, tuple) and x and all(map(callable, x + y)):
            x, y = [f.__name__ for f in x], [f.__name__ for f in y]
        elif hasattr(x, "owns_process") and hasattr(y, "owns_process"):
            # llm_engine.Engine: the add-on's own copy of the class; same name and same bases
            x, y = [[c.__name__ for c in type(e).__mro__] for e in (x, y)]
        elif dataclasses.is_dataclass(x) and not isinstance(x, type) and type(x) is type(y):
            out += [f"{f.name}.{n}" for n in same(x, y)]
            continue
        if x != y:
            out.append(f.name)
    return out


@unittest.skipUnless(shutil.which("ssh-keygen"), "needs OpenSSH's ssh-keygen")
class AdapterAddonsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        tmp = Path(cls.tmp.name)
        key = cls.key = tmp / "key"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "t", "-f", str(key)], check=True)
        cls.signers = f'{addons.PRINCIPAL} namespaces="{addons.NAMESPACE}" ' + \
            " ".join(key.with_suffix(".pub").read_text().split()[:2])
        cls.out = tmp / "addons"
        subprocess.run([sys.executable, str(ROOT / "tools/build-adapter-addons.py"), str(cls.out)], check=True,
                       capture_output=True)
        for folder in cls.out.iterdir():
            cls.sign(folder)
        cls.expect_agents = harnesses.built_in_adapters()
        cls.expect_local = providers.built_in_local()
        cls.expect_online = providers.built_in_online()

    @classmethod
    def sign(cls, folder: Path):
        names = sorted(str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file())
        (folder / "MANIFEST.sha256").write_text("".join(
            f"{hashlib.sha256((folder / n).read_bytes()).hexdigest()}  {n}\n" for n in names))
        subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", str(cls.key), "-n", addons.NAMESPACE,
                        str(folder / "MANIFEST.sha256")], check=True, capture_output=True)
        (folder / "MANIFEST.sha256.sig").rename(folder / "SIGNATURE")

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def tearDown(self):
        addons.load_all(set(), dirs=(), hooks=addon_api.Hooks())

    def load(self, enabled):
        return addons.load_all(enabled, dirs=(self.out,), signers=self.signers, hooks=addon_api.Hooks())

    def test_every_adapter_verifies(self):
        found = self.load(set())
        self.assertEqual(len(found), len(self.expect_agents) + len(self.expect_local) + 1)
        self.assertEqual([a.id for a in found if a.state != "verified"], [])
        claude = next(a for a in found if a.id == "agent-claude")
        self.assertEqual((claude.kind, claude.needs, claude.commands), ("agent", addons.MAPRISMA_VERSION, ["claude"]))
        self.assertIn("updater", claude.capabilities)

    def test_empty_until_switched_on(self):
        self.load(set())
        self.assertEqual((harnesses.all_harnesses(), providers.all_providers()), ((), ()))

    def test_all_on_equals_the_built_ins(self):
        found = self.load({p.name for p in self.out.iterdir()})
        self.assertEqual([a.id for a in found if a.state != "loaded"], [])
        agents = harnesses.all_harnesses()
        self.assertEqual([h.command for h in agents], [h.command for h in self.expect_agents])
        for want, got in zip(self.expect_agents, agents):
            self.assertEqual(same(want, got), [], want.command)
        self.assertEqual([p.key for p in providers.local()], [p.key for p in self.expect_local])
        self.assertEqual([p.key for p in providers.online()], [p.key for p in self.expect_online])
        for want, got in zip(self.expect_local + self.expect_online, providers.all_providers()):
            self.assertEqual(same(want, got), [], want.key)

    def test_one_agent(self):
        self.load({"agent-hermes", "llm-ollama"})
        self.assertEqual([h.command for h in harnesses.all_harnesses()], ["hermes"])
        self.assertEqual([p.key for p in providers.all_providers()], ["ollama"])

    def test_an_agent_without_updater_capability_cannot_update(self):
        api = addon_api.AddonAPI("x", 1, {}, addon_api.Hooks(), ["agent"])
        claude = next(h for h in self.expect_agents if h.command == "claude")
        harnesses.hide_built_in({"claude"})
        self.addCleanup(harnesses.hide_built_in, ())
        with self.assertRaises(addon_api.AddonError):
            api.add_harness(claude)

    def test_needs_a_newer_maprisma(self):
        import json
        folder = Path(self.tmp.name) / "newer" / "agent-x"
        folder.mkdir(parents=True)
        (folder / "addon.json").write_text(json.dumps({"id": "agent-x", "version": "1.0.0", "api": 1,
                                                       "privacy": "numbers", "needs": "maprisma >= 99.0.0"}))
        (folder / "addon.py").write_text("def register(api):\n    pass\n")
        self.sign(folder)
        addon = addons.verify(folder, self.signers)
        self.assertEqual((addon.state, addon.reason),
                         ("refused", f"made for Maprisma 99.0.0 or newer, this is {addons.MAPRISMA_VERSION}"))


if __name__ == "__main__":
    unittest.main()
