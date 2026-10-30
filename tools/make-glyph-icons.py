#!/usr/bin/env python3
"""The app's glyph icons as SVG files, so cards and the map never depend on an installed Nerd Font
or Omarchy's icon font: every glyph the code uses (the Nerd Font escapes in *.py, the agent
adapters' icons, the desktop's agent menu) drawn once by Pango into an outline and written as a
symbolic icon into icons/Maprisma/symbolic/actions/ (icons.name_for() finds it by its code point).

    tools/make-glyph-icons.py            run again when a new glyph is used, then commit the SVGs

Needs the fonts only here, when the icons are made: "JetBrainsMono Nerd Font" (or "Symbols Nerd
Font") and, for Omarchy's agent icons, Omarchy's "omarchy" font.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
import cairo  # noqa: E402
from gi.repository import Pango, PangoCairo  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import icons  # noqa: E402

FONTS = {"": "JetBrainsMono Nerd Font, Symbols Nerd Font", "omarchy": "omarchy"}
SIZE = 64.0                     # drawing size; the SVG is scaled by its viewBox
ESCAPE = re.compile(r"\\U000[Ff]([0-9A-Fa-f]{4})|\\u([eEfF][0-9A-Fa-f]{3})")


def used_glyphs() -> set:
    """(font, character) of every glyph the app uses."""
    found = set()
    for path in ROOT.glob("*.py"):
        for big, small in ESCAPE.findall(path.read_text()):
            found.add(("", chr(int("F" + big, 16)) if big else chr(int(small, 16))))
    import agents
    import harnesses
    for h in harnesses.built_in_adapters():
        if h.icon and len(h.icon) == 1:
            found.add((h.icon_font, h.icon))
    for _command, _label, icon, font in agents.FALLBACK:
        if icon and len(icon) == 1:
            found.add((font, icon))
    try:
        import desktop_omarchy
        for _command, _label, icon, font in desktop_omarchy.agent_catalog() or []:
            if icon and len(icon) == 1:
                found.add((font, icon))
    except Exception:
        pass
    return {(font, ch) for font, ch in found if ord(ch) >= 0xE000}      # private-use: icon fonts only


def outline(char: str, family: str) -> tuple[str, tuple] | None:
    """SVG path data of the glyph and its ink box (x, y, w, h), or None when no font has it."""
    surface = cairo.RecordingSurface(cairo.CONTENT_ALPHA, None)
    cr = cairo.Context(surface)
    layout = PangoCairo.create_layout(cr)
    layout.set_font_description(Pango.FontDescription.from_string(f"{family} {SIZE}px"))
    layout.set_text(char, -1)
    if layout.get_unknown_glyphs_count():
        return None
    ink, _logical = layout.get_pixel_extents()
    if ink.width <= 0 or ink.height <= 0:
        return None
    PangoCairo.layout_path(cr, layout)
    parts = []
    for kind, points in cr.copy_path():
        if kind == cairo.PATH_MOVE_TO:
            parts.append("M{:.2f} {:.2f}".format(*points))
        elif kind == cairo.PATH_LINE_TO:
            parts.append("L{:.2f} {:.2f}".format(*points))
        elif kind == cairo.PATH_CURVE_TO:
            parts.append("C{:.2f} {:.2f} {:.2f} {:.2f} {:.2f} {:.2f}".format(*points))
        elif kind == cairo.PATH_CLOSE_PATH:
            parts.append("Z")
    return " ".join(parts), (ink.x, ink.y, ink.width, ink.height)


def svg(path: str, box: tuple) -> str:
    """A square, centred symbolic icon around the glyph's ink."""
    x, y, w, h = box
    side = max(w, h) * 1.08
    left, top = x + w / 2 - side / 2, y + h / 2 - side / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" '
            f'viewBox="{left:.2f} {top:.2f} {side:.2f} {side:.2f}">'
            f'<path fill="#222222" fill-rule="nonzero" d="{path}"/></svg>\n')


def main() -> int:
    out = icons.THEME_DIR / "symbolic/actions"
    out.mkdir(parents=True, exist_ok=True)
    made, missing = 0, []
    for font, char in sorted(used_glyphs()):
        found = outline(char, FONTS.get(font, FONTS[""]))
        if found is None:
            missing.append(f"{font or 'nerd'} U+{ord(char):X}")
            continue
        (out / f"{icons.glyph_name(char, font)}.svg").write_text(svg(*found))
        made += 1
    print(f"{made} glyph icons in {out}" + (f"; no font has: {', '.join(missing)}" if missing else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
