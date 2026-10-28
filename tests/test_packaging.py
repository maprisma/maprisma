"""The packages carry what the app reads next to its modules at run time: a folder left out (as
adapters/ was once) makes the packaged app fail although every source test passes."""
import ast
import re
import unittest
import hashlib
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = (ROOT / "packaging/appimage/build.sh").read_text()
PKGBUILD = (ROOT / "packaging/aur/PKGBUILD").read_text()


class PackagesCarryTheAppTest(unittest.TestCase):
    def test_runtime_folders_in_both_packages(self):
        for needed in ("translations", "icons", "adapters/*.toml", "adapters/*.py", "user-manual*.pdf",
                       "unpack-adapters.py"):
            with self.subTest(needed=needed):
                self.assertIn(needed, BUILD)
                self.assertIn(needed, PKGBUILD)

    def test_every_manual_language_is_built(self):
        pdfs = sorted(p.name for p in (ROOT / "data").glob("user-manual*.pdf"))
        self.assertEqual(len(pdfs), 8, pdfs)        # English and the seven translations

    def test_versions_match_the_app(self):
        """pkgver is the app's version; the adapter add-ons have releases of their own, of the same
        minor version (a patch release of the app keeps them)."""
        import addons
        self.assertEqual(re.search(r"^pkgver=(\S+)", PKGBUILD, re.M).group(1), addons.ASTERISM_VERSION)
        adapters = re.search(r"^_adapters=(\S+)", PKGBUILD, re.M).group(1)
        self.assertEqual(adapters.split(".")[:2], addons.ASTERISM_VERSION.split(".")[:2])
        self.assertLessEqual(addons.version_tuple(adapters), addons.version_tuple(addons.ASTERISM_VERSION))

    def test_manuals_name_this_version(self):
        """Each built manual's footer names this Asterism version (docs/manual/build.py --all)."""
        import shutil
        import subprocess
        import addons
        if shutil.which("pdftotext") is None:
            self.skipTest("pdftotext not installed")
        for pdf in sorted((ROOT / "data").glob("user-manual*.pdf")):
            with self.subTest(pdf=pdf.name):
                text = subprocess.run(["pdftotext", "-f", "5", "-l", "5", str(pdf), "-"], capture_output=True,
                                      text=True, timeout=30).stdout
                self.assertIn(f"Asterism {addons.ASTERISM_VERSION}", text)

    def test_unpacker_takes_every_file_an_add_on_may_have(self):
        source = (ROOT / "packaging/unpack-adapters.py").read_text()
        allowed = re.search(r'allowed = (\{[^}]*\})', (ROOT / "addons.py").read_text()).group(1)
        for name in ast.literal_eval(allowed):         # addons.verify's set of file names
            with self.subTest(name=name):
                self.assertIn(re.escape(name), source)


class ReleaseAssetTest(unittest.TestCase):
    def test_builder_produces_fixed_alias_and_checksums_without_following_stale_output_links(self):
        # Fixture tools produce inert bytes; no real AppImage, add-on download or signing is run.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for folder in ("packaging/appimage", "translations", "icons", "adapters", "data/icons"):
                (root / folder).mkdir(parents=True)
            (root / "packaging/appimage/build.sh").write_text(BUILD)
            (root / "packaging/appimage/AppRun").write_text("fixture")
            (root / "app.py").write_text("fixture")
            (root / "adapters/fake.toml").write_text("fixture")
            (root / "adapters/fake.py").write_text("fixture")
            (root / "data/user-manual.pdf").write_bytes(b"fixture")
            for filename in ("io.github.ubruckhaus.Asterism.desktop", "io.github.ubruckhaus.Asterism.metainfo.xml",
                             "icons/io.github.ubruckhaus.Asterism.svg"):
                (root / "data" / filename).write_text("fixture")
            (root / "packaging/unpack-adapters.py").write_text("import sys; from pathlib import Path; Path(sys.argv[2]).mkdir(parents=True)")
            tool = root / "appimagetool"
            tool.write_text('#!/usr/bin/env bash\nprintf "fixture AppImage" > "${@: -1}"\n')
            tool.chmod(0o700)
            unrelated = root / "keep"
            unrelated.write_text("keep")
            (root / "Asterism-x86_64.AppImage").symlink_to(unrelated)
            (root / "SHA256SUMS").symlink_to(unrelated)
            result = subprocess.run(["sh", str(root / "packaging/appimage/build.sh"), "1.2.3", str(tool),
                                     str(root / "runtime"), str(root / "adapters.zip")], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(unrelated.read_text(), "keep")
            for filename in ("Asterism-1.2.3-x86_64.AppImage", "Asterism-x86_64.AppImage"):
                self.assertEqual((root / filename).read_bytes(), b"fixture AppImage")
            sums = (root / "SHA256SUMS").read_text().splitlines()
            digest = hashlib.sha256(b"fixture AppImage").hexdigest()
            self.assertEqual(sums, [f"{digest}  Asterism-1.2.3-x86_64.AppImage", f"{digest}  Asterism-x86_64.AppImage"])


if __name__ == "__main__":
    unittest.main()
