"""Per-agent folder choices, cancellation, and the folder actually handed to each terminal."""

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import agent_projects as projects
import agent_start_dialog
import ai_core
import ai_popup
import details_pages
import settings_schema
import terminal_pane


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


class Launcher:
    start_agent = ai_popup.AgentsMap.start_agent
    agent_folder = ai_popup.AgentsMap.agent_folder
    record_agent_project = ai_popup.AgentsMap.record_agent_project

    def __init__(self):
        self.sessions = {}
        self.window = object()
        self.theme = SimpleNamespace(colors={})
        self.right_stack = mock.Mock()
        self.show_terminal = mock.Mock()
        self.show_notice = mock.Mock()
        self.show_view = mock.Mock()
        self.terminal_changed = mock.Mock()
        self.start_outside = mock.Mock()
        self.ask_start_outside = mock.Mock()
        self.save_setting = mock.Mock()
        self.refresh_recent_projects = mock.Mock()
        self.start_gpu_check = lambda agent, go: go()


class ProjectLaunchTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.default = Path(tmp.name) / "default"
        self.project = Path(tmp.name) / "selected project"
        self.default.mkdir()
        self.project.mkdir()
        self.agent = SimpleNamespace(command="test-agent", name="Test Agent")
        self.view = Launcher()
        self.settings = {"agent_folder": str(self.default), "agent_projects": {}, "agent_project_history": {}}
        self.view.save_setting.side_effect = lambda **kw: self.settings.update(kw)
        patches = (
            mock.patch.object(ai_core, "setting", side_effect=self.settings.get),
            mock.patch.object(terminal_pane, "program", return_value="/usr/bin/test-agent"),
            mock.patch.object(agent_start_dialog, "present"),
            mock.patch.object(terminal_pane, "vte", return_value=object()),
            mock.patch.object(terminal_pane, "TerminalPane"),
        )
        self.mocks = [self.enterContext(patch) for patch in patches]
        self.dialog = self.mocks[2]
        self.pane_factory = self.mocks[4]

    def choose(self, remember=True):
        callback = self.dialog.call_args.args[5]
        callback(str(self.project), remember)

    def test_cancel_does_not_launch_or_change_preferences(self):
        self.view.start_agent(self.agent)
        self.dialog.assert_called_once()
        self.pane_factory.assert_not_called()
        self.view.start_outside.assert_not_called()
        self.view.save_setting.assert_not_called()

    def test_embedded_start_remembers_project_for_just_this_agent(self):
        self.view.start_agent(self.agent)
        self.choose()
        self.assertEqual(self.pane_factory.call_args.args[1], str(self.project))
        self.assertEqual(self.settings["agent_projects"], {"test-agent": str(self.project)})
        self.assertEqual(self.settings["agent_folder"], str(self.default))
        self.assertEqual(self.settings["agent_project_history"], {})
        self.pane_factory.call_args.kwargs["on_started"](SimpleNamespace(cwd=str(self.project)))
        self.assertEqual(self.settings["agent_project_history"], {"test-agent": [str(self.project)]})

    def test_no_pin_is_required_for_start(self):
        self.view.start_agent(self.agent)
        self.assertEqual(self.dialog.call_args.args[2], str(self.default))
        self.assertEqual(self.dialog.call_args.kwargs["pinned"], "")
        self.dialog.call_args.args[5](str(self.default), False)
        self.assertEqual(self.pane_factory.call_args.args[1], str(self.default))
        self.assertEqual(self.settings["agent_projects"], {})

    def test_separate_terminal_also_starts_without_any_pin(self):
        self.view.start_agent(self.agent, where="terminal")
        self.assertEqual(self.dialog.call_args.kwargs["pinned"], "")
        self.dialog.call_args.args[5](str(self.default), False)
        self.view.start_outside.assert_called_once_with(self.agent, "/usr/bin/test-agent", str(self.default))
        self.assertEqual(self.settings["agent_projects"], {})

    def test_choosing_a_folder_for_one_session_preserves_pinned_default(self):
        self.settings["agent_projects"] = {"test-agent": str(self.default)}
        self.view.start_agent(self.agent)
        self.dialog.call_args.args[5](str(self.project), None)
        self.assertEqual(self.settings["agent_projects"], {"test-agent": str(self.default)})
        self.assertEqual(self.pane_factory.call_args.args[1], str(self.project))

    def test_history_selection_opens_submenu_without_starting(self):
        self.view.start_agent(self.agent, project=str(self.project))
        self.assertEqual(self.dialog.call_args.args[2], str(self.project))
        self.pane_factory.assert_not_called()

    def test_submenu_receives_all_history_and_pin_without_truncation(self):
        history = [str(self.project)] + [str(self.default / str(i)) for i in range(24)]
        self.settings["agent_project_history"] = {"test-agent": history}
        self.settings["agent_projects"] = {"test-agent": str(self.project)}
        self.view.start_agent(self.agent)
        self.assertEqual(self.dialog.call_args.kwargs["history"], history)
        self.assertEqual(self.dialog.call_args.kwargs["pinned"], str(self.project))

    def test_only_a_successful_outside_terminal_open_is_recorded(self):
        for ok in (False, True):
            view = SimpleNamespace(record_agent_project=mock.Mock(), show_notice=mock.Mock())
            with mock.patch.object(terminal_pane, "open_outside", return_value=ok), \
                    mock.patch.object(ai_popup.agent_status, "remember_issue"):
                ai_popup.AgentsMap.start_outside(view, self.agent, "/usr/bin/test-agent", str(self.project))
            self.assertEqual(view.record_agent_project.call_count, int(ok))

    def test_one_time_project_leaves_remembered_choice_unchanged(self):
        self.settings["agent_projects"] = {"test-agent": str(self.default)}
        self.view.start_agent(self.agent)
        self.choose(remember=False)
        self.assertEqual(self.pane_factory.call_args.args[1], str(self.project))
        self.view.save_setting.assert_not_called()

    def test_separate_terminal_receives_same_project(self):
        self.view.start_agent(self.agent, where="terminal")
        self.choose()
        self.view.start_outside.assert_called_once_with(self.agent, "/usr/bin/test-agent", str(self.project))
        self.pane_factory.assert_not_called()

    def test_restarting_ended_pane_uses_new_project(self):
        pane = mock.Mock(running=False, cwd=str(self.default))
        self.view.sessions[self.agent.command] = pane
        self.view.start_agent(self.agent)
        self.choose()
        self.assertEqual(pane.cwd, str(self.project))
        pane.start.assert_called_once()
        self.pane_factory.assert_not_called()

    def test_running_pane_is_shown_without_relaunch_or_folder_change(self):
        pane = mock.Mock(running=True, cwd=str(self.default))
        self.view.sessions[self.agent.command] = pane
        self.view.start_agent(self.agent)
        self.view.show_terminal.assert_called_once_with(self.agent.command)
        self.dialog.assert_not_called()
        pane.start.assert_not_called()
        self.assertEqual(pane.cwd, str(self.default))

    def test_separate_terminal_can_use_another_project_while_embedded_agent_runs(self):
        pane = mock.Mock(running=True, cwd=str(self.default))
        self.view.sessions[self.agent.command] = pane
        self.view.start_agent(self.agent, where="terminal")
        self.choose(remember=False)
        self.view.start_outside.assert_called_once_with(self.agent, "/usr/bin/test-agent", str(self.project))
        self.assertEqual(pane.cwd, str(self.default))
        pane.start.assert_not_called()

    def test_missing_remembered_folder_is_disclosed_before_default_is_used(self):
        self.settings["agent_projects"] = {"test-agent": str(self.project / "deleted")}
        self.view.start_agent(self.agent)
        self.assertEqual(self.dialog.call_args.args[2], str(self.default))
        self.assertTrue(self.dialog.call_args.kwargs["unavailable"])
        self.pane_factory.assert_not_called()

    def test_missing_vte_keeps_chosen_project_in_fallback(self):
        with mock.patch.object(terminal_pane, "vte", return_value=None), \
                mock.patch.object(ai_popup.agent_status, "remember_issue"):
            self.view.start_agent(self.agent)
            self.choose()
        self.view.ask_start_outside.assert_called_once_with(self.agent, "/usr/bin/test-agent", str(self.project), None)

    def test_deleted_project_between_choice_and_start_does_not_launch(self):
        self.view.start_agent(self.agent)
        self.project.rmdir()
        self.choose()
        self.pane_factory.assert_not_called()
        self.view.save_setting.assert_not_called()
        self.view.show_notice.assert_called_once()

    def test_gpu_check_retains_project_and_revalidates_before_launch(self):
        pending = []
        self.view.start_gpu_check = lambda agent, go: pending.append(go)
        self.view.start_agent(self.agent)
        self.choose()
        self.pane_factory.assert_not_called()
        self.project.rmdir()
        pending[0]()
        self.pane_factory.assert_not_called()
        self.view.show_notice.assert_called_once()


class ProjectCardTest(unittest.TestCase):
    def test_card_lists_all_projects_and_each_row_selects_its_own_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            folders = [Path(tmp) / f"project-{i}" for i in range(15)]
            for folder in folders:
                folder.mkdir()
            history = {"test-agent": [str(p) for p in folders]}
            group = mock.Mock()
            group.get_first_child.return_value = None
            agent = SimpleNamespace(command="test-agent", name="Test Agent", installed=True)
            rows = []
            def plain_row(*_args):
                row = mock.Mock()
                rows.append(row)
                return row
            view = SimpleNamespace(note=mock.Mock(), boxed_list=mock.Mock(), plain_row=plain_row,
                                   start_agent=mock.Mock(), pin_agent_project=mock.Mock(), forget_agent_project=mock.Mock())
            with mock.patch.object(ai_core, "setting", side_effect=lambda key: history if key == "agent_project_history" else {}), \
                    mock.patch.object(details_pages.Gtk, "ToggleButton"), \
                    mock.patch.object(details_pages.Gtk, "Button"), \
                    mock.patch.object(details_pages.Gtk.Image, "new_from_icon_name"), \
                    mock.patch.object(details_pages.Gtk, "ScrolledWindow") as scroller:
                details_pages.DetailsPages.fill_recent_project_rows(view, group, agent)
                self.assertEqual(len(rows), 15)     # no last-ten truncation
                self.assertEqual(scroller.call_args.kwargs["max_content_height"], 300)
                for i in (0, 7, 14):
                    callback = next(c.args[1] for c in rows[i].connect.call_args_list if c.args[0] == "activated")
                    callback(rows[i])
                    self.assertEqual(view.start_agent.call_args.kwargs["project"], str(folders[i]))

    def test_detail_page_pin_and_trash_update_only_this_agent(self):
        with tempfile.TemporaryDirectory() as tmp:
            agent = SimpleNamespace(command="first")
            values = {"agent_projects": {"second": tmp}, "agent_project_history": {"first": [tmp], "second": [tmp]}}
            view = SimpleNamespace(save_setting=lambda **kw: values.update(kw),
                                   fill_recent_project_rows=mock.Mock(), show_notice=mock.Mock())
            with mock.patch.object(ai_core, "setting", side_effect=values.get):
                details_pages.DetailsPages.pin_agent_project(view, agent, tmp, None)
                self.assertEqual(values["agent_projects"], {"first": tmp, "second": tmp})
                details_pages.DetailsPages.pin_agent_project(view, agent, None, None)
                self.assertEqual(values["agent_projects"], {"second": tmp})
                details_pages.DetailsPages.forget_agent_project(view, agent, tmp, None)
                self.assertEqual(values["agent_project_history"], {"first": [], "second": [tmp]})
                self.assertTrue(Path(tmp).is_dir())


class RestartTest(unittest.TestCase):
    def test_history_callback_waits_for_successful_spawn(self):
        pane = SimpleNamespace(set_state=mock.Mock(), short_cwd=lambda: "/project", terminal=mock.Mock(),
                               on_started=mock.Mock(), pid=None)
        terminal_pane.TerminalPane.on_spawned(pane, None, None, SimpleNamespace(message="failed"))
        pane.on_started.assert_not_called()
        terminal_pane.TerminalPane.on_spawned(pane, None, 123, None)
        pane.on_started.assert_called_once_with(pane)

    def test_restart_action_offers_project_choice_without_spawning_directly(self):
        pane = SimpleNamespace(running=False, on_restart=mock.Mock(), start=mock.Mock())
        terminal_pane.TerminalPane.restart(pane)
        pane.on_restart.assert_called_once()
        pane.start.assert_not_called()

    def test_fixed_command_panes_keep_their_original_restart(self):
        pane = SimpleNamespace(running=False, on_restart=None, start=mock.Mock())
        terminal_pane.TerminalPane.restart(pane)
        pane.start.assert_called_once()

    def test_running_agent_cannot_spawn_twice(self):
        pane = SimpleNamespace(running=True, on_restart=mock.Mock(), start=mock.Mock())
        terminal_pane.TerminalPane.restart(pane)
        pane.on_restart.assert_not_called()
        pane.start.assert_not_called()


if __name__ == "__main__":
    unittest.main()
