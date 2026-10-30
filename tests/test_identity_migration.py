"""App identity across desktops and non-destructive first-start migration in a temporary HOME."""

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ai_core
import ai_helper
import config_migration as migration
import desktop
import desktop_generic
import desktop_omarchy
import identity
import provider_watch


class IdentityTest(unittest.TestCase):
    def test_build_identity_does_not_change_with_desktop(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(identity, "HOME", Path(tmp)), \
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(Path(tmp) / ".config")}):
            for plugin, name, app_id, config in (
                (False, "Asterism", "io.github.ubruckhaus.Asterism", "asterism"),
                (True, "AI Agents Map", "org.omarchy.aiagentsmap", "omarchy/ai-agents-map"),
            ):
                for backend in (desktop_generic, desktop_omarchy):
                    with self.subTest(plugin=plugin, backend=backend.NAME), \
                            mock.patch.object(identity, "is_plugin", return_value=plugin), \
                            mock.patch.object(desktop, "current", return_value=backend):
                        self.assertEqual(desktop.app_name(), name)
                        self.assertEqual(desktop.app_id(), app_id)
                        self.assertEqual(desktop.config_dir(), Path(tmp) / ".config" / config)
                        self.assertEqual(ai_helper.plugin_id(), "ai-agents-map" if plugin else "asterism")
                        self.assertEqual(provider_watch._unit_name(), identity.short_name() + "-providers.service")
                        self.assertEqual(desktop.launcher_entry(), plugin and backend.NAME == "omarchy")

    def test_plugin_build_is_detected_without_importing_addon_code(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(identity, "ROOT", Path(tmp)):
            self.assertTrue(identity.is_plugin())
            (Path(tmp) / "addons.py").write_text('raise RuntimeError("must not execute")')
            self.assertFalse(identity.is_plugin())

    def test_xdg_config_is_supported_and_relative_values_are_ignored(self):
        with mock.patch.object(identity, "is_plugin", return_value=False), \
                mock.patch.object(identity, "HOME", Path("/home/test")):
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/custom/config"}):
                self.assertEqual(identity.config_dir(), Path("/custom/config/asterism"))
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "relative"}):
                self.assertEqual(identity.config_dir(), Path("/home/test/.config/asterism"))



class MigrationTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.source = self.home / ".config/omarchy/ai-agents-map"
        self.target = self.home / ".config/asterism"
        self.source.mkdir(parents=True)
        self.enterContext(mock.patch.object(identity, "HOME", self.home))
        self.enterContext(mock.patch.object(identity, "is_plugin", return_value=False))
        self.enterContext(mock.patch.dict(os.environ, {"HOME": str(self.home), "XDG_CONFIG_HOME": str(self.home / ".config")}))
        self.original = {
            "settings.json": b'{"look":"omarchy","map_zoom":1.3}',
            "mcp-servers.json": b'{"servers":[]}',
            "failed-links.json": b'{}',
            "providers-with-agents.json": b'{"providers":[]}',
            "agents/custom-agent.json": b'{"custom":true}',
        }
        for name, data in self.original.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def run_migration(self):
        return migration.migrate()

    def test_copy_backup_modes_and_originals(self):
        before = {name: (self.source / name).stat().st_mtime_ns for name in self.original}
        self.assertTrue(self.run_migration())
        settings = json.loads((self.target / "settings.json").read_text())
        self.assertEqual(settings["look"], "omarchy")
        self.assertTrue(settings["plugin_migration"]["addons_pending"])
        backup = self.target / settings["plugin_migration"]["backup"]
        for name, data in self.original.items():
            self.assertEqual((self.source / name).read_bytes(), data)
            self.assertEqual((self.source / name).stat().st_mtime_ns, before[name])
            self.assertEqual((backup / name).read_bytes(), data)
            if name != "settings.json":
                self.assertEqual((self.target / name).read_bytes(), data)
                self.assertNotEqual((self.target / name).stat().st_ino, (backup / name).stat().st_ino)
            self.assertEqual(stat.S_IMODE((self.target / name).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        (self.target / "mcp-servers.json").write_bytes(b"edited in place")
        self.assertEqual((backup / "mcp-servers.json").read_bytes(), self.original["mcp-servers.json"])

    def test_once_only_existing_asterism_settings_win(self):
        self.assertTrue(self.run_migration())
        original = (self.target / "settings.json").read_bytes()
        (self.source / "settings.json").write_text("invalid source no longer matters")
        with mock.patch.object(migration, "_snapshot") as snapshot:
            self.assertFalse(self.run_migration())
            snapshot.assert_not_called()
        self.assertEqual((self.target / "settings.json").read_bytes(), original)

    def test_no_source_settings_does_not_create_an_asterism_config(self):
        (self.source / "settings.json").unlink()
        self.assertFalse(self.run_migration())
        self.assertFalse(self.target.exists())

    def test_plugin_edition_never_migrates(self):
        with mock.patch.object(identity, "is_plugin", return_value=True):
            self.assertFalse(self.run_migration())
        self.assertFalse(self.target.exists())

    def test_another_start_finishing_before_the_lock_is_not_overwritten(self):
        def other_start(_fd, _operation):
            (self.target / "settings.json").write_bytes(b'{"other_start":true}')
        with mock.patch.object(migration.fcntl, "flock", side_effect=other_start):
            self.assertFalse(self.run_migration())
        self.assertEqual((self.target / "settings.json").read_bytes(), b'{"other_start":true}')
        self.assertFalse(list(self.target.glob("plugin-backup-*")))

    def test_preexisting_standalone_auxiliary_files_are_preserved(self):
        self.target.mkdir()
        (self.target / "mcp-servers.json").write_bytes(b"my standalone data")
        self.assertTrue(self.run_migration())
        self.assertEqual((self.target / "mcp-servers.json").read_bytes(), b"my standalone data")

    def test_source_symlink_is_never_read(self):
        (self.source / "settings.json").unlink()
        (self.source / "settings.json").symlink_to(self.source / "mcp-servers.json")
        with self.assertRaises(OSError):
            self.run_migration()
        self.assertFalse(self.target.exists())

    def test_symlinked_profile_directory_is_refused(self):
        profiles = self.source / "agents"
        profiles.rename(self.source / "profiles")
        profiles.symlink_to(self.source / "profiles", target_is_directory=True)
        with self.assertRaises(OSError):
            self.run_migration()
        self.assertFalse(self.target.exists())

    def test_credentials_and_unrelated_files_are_not_read_or_copied(self):
        (self.source / "agents/auth.json").write_text("credential fixture")
        (self.source / "agents/.credentials.json").write_text("credential fixture")
        (self.source / "unrelated.json").write_text("unrelated")
        original = migration._read
        names = []
        def read(fd, name, limit=migration.MAX_FILE):
            names.append(name)
            return original(fd, name, limit)
        with mock.patch.object(migration, "_read", side_effect=read):
            self.assertTrue(self.run_migration())
        self.assertNotIn("auth.json", names)
        self.assertNotIn(".credentials.json", names)
        self.assertNotIn("unrelated.json", names)
        self.assertFalse((self.target / "agents/auth.json").exists())

    def test_fifo_and_oversize_settings_fail_without_overwriting_anything(self):
        file = self.source / "settings.json"
        file.unlink()
        os.mkfifo(file)
        with self.assertRaises(ValueError):
            self.run_migration()
        file.unlink()
        file.write_bytes(b" " * (migration.MAX_SETTINGS + 1))
        with self.assertRaises(ValueError):
            self.run_migration()
        self.assertFalse(self.target.exists())

    def test_invalid_settings_are_rejected_before_target_creation(self):
        for value in (b"[]", b"invalid"):
            (self.source / "settings.json").write_bytes(value)
            with self.assertRaises(ValueError):
                self.run_migration()
            self.assertFalse(self.target.exists())

    def test_failure_before_settings_commit_rolls_back_new_files_and_backup(self):
        link = migration.os.link
        def fail_settings(src, dst, **kwargs):
            if dst == "settings.json":
                raise OSError("simulated write failure")
            return link(src, dst, **kwargs)
        with mock.patch.object(migration.os, "link", side_effect=fail_settings):
            with self.assertRaises(OSError):
                self.run_migration()
        self.assertFalse((self.target / "settings.json").exists())
        self.assertFalse((self.target / "mcp-servers.json").exists())
        backups = list(self.target.glob("plugin-backup-*"))
        self.assertEqual(backups, [])
        self.assertEqual((self.source / "settings.json").read_bytes(), self.original["settings.json"])
        self.assertTrue(self.run_migration())


if __name__ == "__main__":
    unittest.main()


class MigrationHomeAncestorTest(unittest.TestCase):
    def test_resolved_home_ancestor_and_config_link_are_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            real = root / 'real-home'
            real.mkdir()
            alias = root / 'home-link'
            alias.symlink_to(real, target_is_directory=True)
            config = root / 'dotfiles'
            config.mkdir()
            (real / '.config').symlink_to(config, target_is_directory=True)
            (config / 'asterism').mkdir()
            with mock.patch.object(Path, 'home', return_value=alias):
                fd = migration._directory(alias / '.config/asterism')
            try:
                self.assertEqual(os.fstat(fd).st_ino, (config / 'asterism').stat().st_ino)
            finally:
                os.close(fd)


class MigrationFailedBackupTest(unittest.TestCase):
    def test_late_import_failure_leaves_no_published_backups(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root/'source', root/'target'
            (source/'agents').mkdir(parents=True)
            (source/'settings.json').write_text('{}')
            (source/'agents/fixture.json').write_text('{}')
            target.mkdir()
            elsewhere = root/'elsewhere'
            elsewhere.mkdir()
            (target/'agents').symlink_to(elsewhere, target_is_directory=True)
            with mock.patch.object(identity, 'is_plugin', return_value=False):
                for _ in range(2):
                    with self.assertRaises((OSError,ValueError)):
                        migration.migrate(source, target)
                    self.assertEqual(list(target.glob('plugin-backup-*')), [])
                    self.assertFalse((target/'settings.json').exists())
            self.assertEqual((source/'settings.json').read_text(), '{}')


