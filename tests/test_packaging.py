"""The packages carry what the app reads next to its modules at run time: a folder left out (as
adapters/ was once) makes the packaged app fail although every source test passes."""
import ast
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class PackagedDataTest(unittest.TestCase):
    """What a package of the app will carry (the GTK AppImage and AUR packages were removed in phase 7;
    the Flutter packaging comes with plan-flutter.md step 6)."""

    def test_every_manual_language_is_built(self):
        pdfs = sorted(p.name for p in (ROOT / "data").glob("user-manual*.pdf"))
        self.assertEqual(len(pdfs), 8, pdfs)        # English and the seven translations

    def test_manuals_name_this_version(self):
        """Each built manual's footer names this Maprisma version (docs/manual/build.py --all)."""
        import shutil
        import subprocess
        import addons
        if shutil.which("pdftotext") is None:
            self.skipTest("pdftotext not installed")
        for pdf in sorted((ROOT / "data").glob("user-manual*.pdf")):
            with self.subTest(pdf=pdf.name):
                text = subprocess.run(["pdftotext", "-f", "5", "-l", "5", str(pdf), "-"], capture_output=True,
                                      text=True, timeout=30).stdout
                self.assertIn(f"Maprisma {addons.MAPRISMA_VERSION}", text)

    def test_unpacker_takes_every_file_an_add_on_may_have(self):
        source = (ROOT / "packaging/unpack-adapters.py").read_text()
        allowed = re.search(r'allowed = (\{[^}]*\})', (ROOT / "addons.py").read_text()).group(1)
        for name in ast.literal_eval(allowed):         # addons.verify's set of file names
            with self.subTest(name=name):
                self.assertIn(re.escape(name), source)


if __name__ == "__main__":
    unittest.main()
