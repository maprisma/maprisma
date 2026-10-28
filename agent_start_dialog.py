"""Start submenu: current default, folder picker and searchable project history."""

from __future__ import annotations

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, GLib, Gtk, Pango  # noqa: E402

import agent_projects
from i18n import _


def present(parent, name: str, initial: str, default: str, start_label: str, on_start,
            unavailable: bool = False, history=(), pinned: str = "", anchor=None):
    popover = Gtk.Popover()
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10,
                  margin_top=12, margin_bottom=12, margin_start=12, margin_end=12)
    title = Gtk.Label(label=_("Start {0}").format(name), xalign=0)
    title.add_css_class("heading")
    box.append(title)
    start = Gtk.Button(label=start_label)
    start.add_css_class("suggested-action")
    box.append(start)
    path_label = Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE, max_width_chars=40)
    box.append(path_label)
    status = Gtk.Label(xalign=0)
    status.add_css_class("dim-label")
    box.append(status)
    box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
    choose = Gtk.Button(label=_("Choose folder…"))
    box.append(choose)
    reset = Gtk.Button(label=_("Use default folder"))
    box.append(reset)
    box.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
    box.append(Gtk.Label(label=_("Recent projects"), xalign=0))
    paths = list(history)
    labels = [_("Select a recent project…")] + [p + (" · " + _("Pinned default") if p == pinned else "") for p in paths]
    drop = Gtk.DropDown.new_from_strings(labels)
    drop.set_enable_search(True)
    drop.set_sensitive(bool(paths))
    drop.set_selected(paths.index(initial) + 1 if initial in paths else 0)

    def factory():
        made = Gtk.SignalListItemFactory()
        def setup(_factory, item):
            item.set_child(Gtk.Label(xalign=0, ellipsize=Pango.EllipsizeMode.MIDDLE, max_width_chars=40))
        def bind(_factory, item):
            text = item.get_item().get_string()
            item.get_child().set_label(text)
            item.get_child().set_tooltip_text(text)
        made.connect("setup", setup)
        made.connect("bind", bind)
        return made
    drop.set_factory(factory())
    drop.set_list_factory(factory())
    box.append(drop)                       # Gtk.DropDown's popup scrolls and supports searching.
    if not paths:
        empty = Gtk.Label(label=_("No recent projects yet"), xalign=0)
        empty.add_css_class("dim-label")
        box.append(empty)
    pin = Gtk.CheckButton(label=_("Pin as default for {0}").format(name))
    box.append(pin)
    error = Gtk.Label(xalign=0, wrap=True, max_width_chars=40)
    error.add_css_class("error")
    box.append(error)
    chosen = initial

    def update(value: str):
        nonlocal chosen
        chosen = value
        path_label.set_label(value)
        path_label.set_tooltip_text(value)
        status.set_label(_("Pinned default") if value == pinned else _("Default folder")
                         if value == default else _("Selected project"))
        pin.set_active(value == pinned)
        valid = agent_projects.folder(value) is not None
        error.set_label(_("This folder is unavailable. Choose another folder or use the default."))
        error.set_visible(not valid)
        start.set_sensitive(valid)
        pin.set_sensitive(valid)

    def picked(source, result):
        try:
            selected = source.select_folder_finish(result)
        except GLib.Error:
            return
        if selected is not None and selected.get_path():
            on_start(selected.get_path(), None)   # One session; a folder choice never silently pins it.

    def pick(*_args):
        picker = Gtk.FileDialog(title=_("Choose a project folder"), modal=True)
        current = agent_projects.folder(chosen)
        if current:
            picker.set_initial_folder(Gio.File.new_for_path(current))
        popover.popdown()
        picker.select_folder(parent, None, picked)

    def launch(*_args):
        popover.popdown()
        on_start(chosen, pin.get_active())

    def recent_selected(source, _property):
        index = source.get_selected() - 1
        if 0 <= index < len(paths):
            update(paths[index])
    drop.connect("notify::selected", recent_selected)
    choose.connect("clicked", pick)
    start.connect("clicked", launch)
    reset.connect("clicked", lambda *_: (drop.set_selected(0), update(default)))
    update(initial)
    if unavailable:
        error.set_label(_("The remembered folder is unavailable. The default folder is shown instead."))
        error.set_visible(True)
    popover.set_child(box)
    popover.set_parent(anchor if anchor is not None else parent)
    popover.connect("closed", lambda p: GLib.idle_add(p.unparent))
    popover.popup()
    start.grab_focus()
    return popover
