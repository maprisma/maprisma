import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


class CollabColourTest(unittest.TestCase):
    """Lines between agents working together have their own colour: from the theme, none of the others."""

    def test_its_own_colour(self):
        import palette
        colors = dict(palette.DEFAULT_COLORS)
        collab = palette.collab_color(colors)
        self.assertRegex(collab, r"^#[0-9a-f]{6}$")
        taken = {colors[k] for k in ("accent", "red", "yellow", "green", "magenta", "cyan", "orange", "foreground")}
        self.assertNotIn(collab, taken)
        self.assertNotEqual(palette.collab_color({**colors, "red": "#ff0000"}), collab)   # follows the theme

if __name__ == "__main__":
    unittest.main()
