"""Per-agent folder choices, cancellation, and the folder actually handed to each terminal."""

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import agent_projects as projects
import ai_core
import settings_schema


class ProjectPolicyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.default = self.root / "default"
        self.one = self.root / "project with spaces; $literal"
        self.two = self.root / "other"
        for folder in (self.default, self.one, self.two):
            folder.mkdir()

    def test_agents_keep_independent_projects_and_default_is_unchanged(self):
        saved = projects.pin("first", str(self.one), {})
        saved = projects.pin("second", str(self.two), saved)
        self.assertEqual(projects.selected("first", saved, str(self.default)), str(self.one))
        self.assertEqual(projects.selected("second", saved, str(self.default)), str(self.two))
        self.assertEqual(projects.selected("third", saved, str(self.default)), str(self.default))
        self.assertEqual(saved["first"], str(self.one))

    def test_unpin_clears_only_the_selected_agent(self):
        original = {"first": str(self.one), "second": str(self.two)}
        saved = projects.pin("first", None, original)
        self.assertEqual(saved, {"second": str(self.two)})
        self.assertIn("first", original)

    def test_link_is_resolved_to_real_project(self):
        link = self.root / "link"
        link.symlink_to(self.one, target_is_directory=True)
        self.assertEqual(projects.folder(str(link)), str(self.one))

    def test_missing_malformed_relative_and_regular_files_are_not_projects(self):
        file = self.root / "file"
        file.touch()
        for value in (None, {}, 12, "", "relative", "bad\0path", str(file), str(self.root / "missing")):
            self.assertIsNone(projects.folder(value), repr(value))
        with self.assertRaises(ValueError):
            projects.pin("first", str(file), {})
        self.assertEqual(projects.selected("first", {"first": str(file)}, str(self.default)), str(self.default))

    def test_settings_schema_refuses_invalid_mapping(self):
        valid = settings_schema.SCHEMA["agent_projects"].valid
        self.assertTrue(valid({"first": str(self.one)}))
        self.assertFalse(valid({"first": [str(self.one)]}))
        self.assertFalse(valid([]))

    def test_history_retains_all_projects_newest_first_without_duplicates(self):
        saved = {}
        paths = []
        for i in range(30):
            path = self.root / f"project-{i}"
            path.mkdir()
            paths.append(str(path))
            saved = projects.used("first", str(path), saved)
        self.assertEqual(projects.history("first", saved), paths[::-1])
        saved = projects.used("first", paths[0], saved)
        self.assertEqual(projects.history("first", saved), [paths[0]] + paths[:0:-1])
        self.assertEqual(len(saved["first"]), 30)

    def test_histories_are_independent_and_use_does_not_pin(self):
        saved = projects.used("first", str(self.one), {})
        saved = projects.used("second", str(self.two), saved)
        self.assertEqual(projects.history("first", saved), [str(self.one)])
        self.assertEqual(projects.history("second", saved), [str(self.two)])
        self.assertEqual(projects.selected("first", {}, str(self.default)), str(self.default))

    def test_forget_clears_only_that_history_entry_and_its_pin_and_keeps_files(self):
        file = self.one / "keep.txt"
        file.write_text("keep")
        saved = {"first": [str(self.one), str(self.two)], "second": [str(self.one)]}
        pins = {"first": str(self.one), "second": str(self.one)}
        history, pinned = projects.forget("first", str(self.one), saved, pins)
        self.assertEqual(history, {"first": [str(self.two)], "second": [str(self.one)]})
        self.assertEqual(pinned, {"second": str(self.one)})
        self.assertEqual(file.read_text(), "keep")
        self.assertEqual(saved["first"], [str(self.one), str(self.two)])

    def test_missing_history_folder_is_retained_for_removal(self):
        saved = projects.used("first", str(self.one), {})
        self.one.rmdir()
        self.assertEqual(projects.history("first", saved), [str(self.one)])
        self.assertEqual(projects.forget("first", str(self.one), saved, {})[0], {"first": []})

    def test_a_pin_is_optional_and_may_explicitly_pin_the_global_default(self):
        self.assertEqual(projects.selected("first", {}, str(self.default)), str(self.default))
        saved = projects.pin("first", str(self.default), {})
        self.assertEqual(projects.selected("first", saved, str(self.two)), str(self.default))
        self.assertEqual(projects.pin("first", None, saved), {})

    def test_history_schema_rejects_non_lists_and_bad_items(self):
        valid = settings_schema.SCHEMA["agent_project_history"].valid
        self.assertTrue(valid({"first": [str(self.one)]}))
        self.assertFalse(valid({"first": str(self.one)}))
        self.assertFalse(valid({"first": [123]}))


if __name__ == "__main__":
    unittest.main()
