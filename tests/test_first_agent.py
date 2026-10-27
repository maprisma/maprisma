import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import first_agent as fa  # noqa: E402

GB = 1000 ** 3


class CatalogTest(unittest.TestCase):
    def test_the_apps_catalog_holds_four_routes_and_models_that_fit_an_agent(self):
        catalog = fa.load()
        self.assertEqual([r.id for r in catalog.routes], ["claude", "codex", "llamacpp-pi", "ollama-opencode"])
        self.assertTrue(all(r.runtime for r in catalog.routes if r.kind == "local"))
        self.assertTrue(catalog.models and all(m.context >= fa.MIN_CONTEXT for m in catalog.models))

    def test_entries_that_do_not_hold_up_are_left_out(self):
        catalog = fa.parse({"routes": [
            {"id": "ok", "kind": "online", "agent": "claude", "title": "Claude Code", "needs": ["mise"]},
            {"id": "bad need", "kind": "online", "agent": "x", "title": "X", "needs": ["curl | sh"]},
            {"id": "evil", "kind": "online", "agent": "x", "title": "X", "pricing": "http://example.com"},
            {"id": "nolocal", "kind": "local", "agent": "pi", "title": "Pi"},           # no runtime
            {"id": "agent", "kind": "online", "agent": "../bin/sh", "title": "Sh"}],
            "models": [
            {"id": "m", "title": "M", "repo": "a/b", "file": "m.gguf", "bytes": 1, "min_vram": 2, "context": 32768},
            {"id": "path", "title": "P", "repo": "a/b", "file": "../m.gguf", "bytes": 1, "min_vram": 2},
            {"id": "small", "title": "S", "repo": "a/b", "file": "s.gguf", "bytes": 1, "min_vram": 2, "context": 4096}]})
        self.assertEqual([r.id for r in catalog.routes], ["ok"])
        self.assertEqual([m.id for m in catalog.models], ["m"])

    def test_a_signed_addons_catalog_is_read_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / "first-agent.json").write_text(json.dumps({"routes": [
                {"id": "only", "kind": "online", "agent": "codex", "title": "Codex"}]}))
            addon = mock.Mock(state="loaded", folder=folder, files={"first-agent.json": b""})
            self.assertEqual([r.id for r in fa.load(loaded_addons=[addon]).routes], ["only"])
            addon.state = "verified"                       # not switched on: the app's own
            self.assertEqual(fa.load(loaded_addons=[addon]).routes[0].id, "claude")


class ModelsTest(unittest.TestCase):
    def test_the_largest_that_fits_is_suggested(self):
        models = fa.load().models
        self.assertEqual(fa.suggested(models, 24 * GB).bytes, max(m.bytes for m in models
                                                                   if m.min_vram <= 24 * GB))
        self.assertEqual(fa.suggested(models, 8 * GB).id, "gemma-4-e2b")
        self.assertEqual(fa.suggested(models, 0).id, "gemma-4-e2b")                  # no card known: smallest
        big = next(m for m in models if m.id == "gemma-4-26b-a4b")
        self.assertEqual((fa.fit(big, 24 * GB), fa.fit(big, 19 * GB), fa.fit(big, 8 * GB)),
                         ("fits", "partly", "too large"))


class NeedsTest(unittest.TestCase):
    def test_what_is_missing_comes_in_order(self):
        route = next(r for r in fa.load().routes if r.id == "llamacpp-pi")
        with mock.patch.object(fa, "has_tool", return_value=False), mock.patch.object(fa, "node_ready", return_value=False):
            self.assertEqual(fa.missing(route), ["mise", "node"])
            self.assertIn("systemctl", fa.blockers(route))
        with mock.patch.object(fa, "has_tool", return_value=True), mock.patch.object(fa, "node_ready", return_value=True):
            self.assertEqual((fa.missing(route), fa.blockers(route)), ([], []))

    def test_the_guide_is_needed_until_one_agent_works(self):
        with mock.patch.object(fa, "state", return_value={}):
            self.assertTrue(fa.needs_guide(set(), lambda c: False))
            self.assertTrue(fa.needs_guide({"claude"}, lambda c: False))           # installed, not signed in
            self.assertFalse(fa.needs_guide({"claude"}, lambda c: True))
        with mock.patch.object(fa, "state", return_value={"verified": ["pi"]}):
            self.assertFalse(fa.needs_guide({"pi"}, lambda c: False))


class VerifyTest(unittest.TestCase):
    def test_the_test_uses_the_agents_own_ask_command(self):
        argv = fa.verify_argv("claude")
        self.assertIn(fa.TEST_PROMPT, argv)
        self.assertIn("--strict-mcp-config", argv)
        for route in fa.load().routes:                   # every route's agent can be tested
            self.assertIsNotNone(fa.verify_argv(route.agent), route.agent)
        self.assertEqual(fa.answer_ok(b"  Yes, ready.\n", True), "Yes, ready.")
        self.assertEqual(fa.answer_ok(b"Yes", False), "")


if __name__ == "__main__":
    unittest.main()
