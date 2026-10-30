"""Maprisma's identity is the same on every desktop; it knows nothing of the GTK app AI Agents Map."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import ai_helper
import desktop
import desktop_generic
import desktop_omarchy
import identity
import provider_watch


class IdentityTest(unittest.TestCase):
    def test_identity_does_not_change_with_desktop(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(identity, "HOME", Path(tmp)), \
                mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(Path(tmp) / ".config")}):
            for backend in (desktop_generic, desktop_omarchy):
                with self.subTest(backend=backend.NAME), mock.patch.object(desktop, "current", return_value=backend):
                    self.assertEqual(desktop.app_name(), "Maprisma")
                    self.assertEqual(desktop.app_id(), "com.maprisma.Maprisma")
                    self.assertEqual(desktop.config_dir(), Path(tmp) / ".config/maprisma")
                    self.assertEqual(ai_helper.plugin_id(), "maprisma")
                    self.assertEqual(provider_watch._unit_name(), "maprisma-providers.service")
                    self.assertFalse(desktop.launcher_entry())     # the package brings the launcher

    def test_xdg_config_is_supported_and_relative_values_are_ignored(self):
        with mock.patch.object(identity, "HOME", Path("/home/test")):
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "/custom/config"}):
                self.assertEqual(identity.config_dir(), Path("/custom/config/maprisma"))
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": "relative"}):
                self.assertEqual(identity.config_dir(), Path("/home/test/.config/maprisma"))


if __name__ == "__main__":
    unittest.main()
