"""Texts the GTK pages built from reference data, kept here as the reference for the Dart core's ports
(phase 7 removed the GTK UI from this tree; its frozen copy is the plugin repo's). Copied unchanged from
ui_helpers.short_number and size_text, details_pages.duration_text and mcp_pages.mcp_rows; the parity
tests compare the Dart core's texts with these. Nothing here runs in the app."""

import harnesses
import mcp_ctl
import skills_ctl
from i18n import _


def short_number(n: int) -> str:
    """36835328 -> "36.8M"."""
    for size, suffix in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "k")):
        if n >= size:
            return f"{n / size:.1f}".rstrip("0").rstrip(".") + suffix
    return str(n)


def size_text(n: int) -> str:
    """2490000000 -> "2.5 GB"."""
    for size, unit in ((1e12, "TB"), (1e9, "GB"), (1e6, "MB")):
        if n >= size:
            return f"{n / size:.1f} {unit}"
    return f"{max(0, n) // 1000} kB"


def duration_text(seconds: float) -> str:
    minutes = int(seconds // 60)
    return _("{0} h {1} min").format(minutes // 60, minutes % 60) if minutes >= 60 else \
        _("{0} min").format(minutes)


def mcp_rows(command: str, entry) -> list:
    """(label, value, tip) of one agent's entry. Values of env and headers stay hidden."""
    files = mcp_ctl.paths_for(command)
    harness = harnesses.get(command)
    file = skills_ctl.tilde(files[0]) if files else harness.mcp.path if harness and harness.mcp else ""
    rows = [(_("Settings file"), file, _("Where this agent keeps the server."))]
    if entry is None:
        return rows + [(_("Type"), _("cannot be read"), "")]
    if entry["transport"] == "stdio":
        import shlex
        rows += [(_("Type"), _("runs a program (stdio)"), ""),
                 (_("Command"), entry["command"], ""),
                 (_("Arguments"), " ".join(shlex.quote(a) for a in entry["args"]), "")]
        hidden = entry["env"]
        rows.append((_("Environment"), ", ".join(f"{k} = •••" for k in hidden),
                     _("Values are not shown: they may be keys or tokens.")))
    else:
        from urllib.parse import urlsplit
        parts = urlsplit(entry["url"])
        address = f"{parts.scheme}://{parts.netloc}{parts.path}" + (" ?…" if parts.query else "")
        rows += [(_("Type"), _("remote server (HTTP)") if entry["transport"] == "http"
                  else _("remote server (SSE)"), ""),
                 (_("Address"), address, _("Query parameters are not shown: they may hold a token.")),
                 (_("Headers"), ", ".join(f"{k}: •••" for k in entry["headers"]),
                  _("Values are not shown: they may be keys or tokens."))]
    return rows
