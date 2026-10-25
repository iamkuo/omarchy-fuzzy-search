#!/usr/bin/env python3
"""Fuzzy Search settings.

A plain GTK4/libadwaita application window, so it stacks, focuses, and closes
like any other app instead of living on the Omarchy menu's always-on-top
layer. All index work happens in detached processes owned by
bin/omarchy-search-config, so closing this window never stops a build and
reopening it picks the current state back up from status.json.
"""

import json
import os
import subprocess
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_SCRIPT = os.path.join(HERE, "bin", "omarchy-search-config")
CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "omarchy-search",
)
STATUS_PATH = os.path.join(CACHE_DIR, "status.json")

TTL_OPTIONS = [60, 300, 900, 1800, 3600]
TTL_LABELS = ["Every minute", "Every 5 minutes", "Every 15 minutes", "Every 30 minutes", "Every hour"]


def config_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "omarchy", "fuzzy-search.json")


def run_config(*args: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [CONFIG_SCRIPT, *args],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return proc.returncode, proc.stdout, proc.stderr.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, "", str(error)


def read_config() -> dict:
    try:
        with open(config_path(), "r", encoding="utf-8") as handle:
            value = json.load(handle)
            return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def read_stats() -> dict:
    code, out, _ = run_config("stats")
    if code != 0:
        return {}
    try:
        return json.loads(out)
    except ValueError:
        return {}


def short_path(path: str) -> str:
    home = os.path.expanduser("~")
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~/" + path[len(home) + 1 :]
    return path


def format_count(value) -> str:
    try:
        return f"{max(0, int(value)):,}"
    except (TypeError, ValueError):
        return "0"


def format_bytes(value) -> str:
    try:
        size = float(value)
    except (TypeError, ValueError):
        size = 0
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024
    return "0 B"


def format_age(seconds) -> str:
    try:
        value = int(seconds)
    except (TypeError, ValueError):
        return "not built yet"
    if value < 0:
        return "not built yet"
    if value < 90:
        return "just now"
    if value < 3600:
        return f"{round(value / 60)} min ago"
    if value < 86400:
        return f"{round(value / 3600)} h ago"
    return f"{round(value / 86400)} d ago"


class SettingsWindow(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Fuzzy Search Settings")
        self.set_default_size(520, 460)
        self.set_size_request(420, 340)

        self.stats = {}
        self.config = {}
        self._root_rows = []
        self._roots_key = None
        self._build_ui()

        key = Gtk.EventControllerKey()
        key.connect("key-pressed", self._on_key)
        self.add_controller(key)

        self._timer = GLib.timeout_add(1000, self._tick)
        self.refresh()

    # ---------------------------------------------------------------- layout

    def _build_ui(self):
        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar.add_top_bar(header)
        self.set_content(toolbar)

        self.toasts = Adw.ToastOverlay()
        toolbar.set_content(self.toasts)

        self.page = Adw.PreferencesPage()
        self.toasts.set_child(self.page)

        self.folders_group = Adw.PreferencesGroup(
            title="Indexed folders",
            description="Super+Space searches every file under these folders.",
        )
        add_button = Gtk.Button(label="Add Folder…", valign=Gtk.Align.CENTER)
        add_button.add_css_class("flat")
        add_button.connect("clicked", self._choose_folder)
        self.folders_group.set_header_suffix(add_button)
        self.page.add(self.folders_group)

        options = Adw.PreferencesGroup(title="Options")
        self.page.add(options)

        self.hidden_row = Adw.SwitchRow(
            title="Include hidden files",
            subtitle="Index dotfiles and hidden directories",
        )
        self.hidden_row.connect("notify::active", self._on_hidden)
        options.add(self.hidden_row)

        self.local_row = Adw.SwitchRow(
            title="Stay on local filesystem",
            subtitle="Skip network and FUSE mounts; recommended on BTRFS",
        )
        self.local_row.connect("notify::active", self._on_local)
        options.add(self.local_row)

        self.ttl_row = Adw.ComboRow(
            title="Refresh index",
            model=Gtk.StringList.new(TTL_LABELS),
        )
        self.ttl_row.connect("notify::selected", self._on_ttl)
        options.add(self.ttl_row)

        index_group = Adw.PreferencesGroup(title="Index")
        self.page.add(index_group)

        self.rebuild_row = Adw.ActionRow(title="Rebuild index now", subtitle="No index yet")
        self.spinner = Gtk.Spinner(valign=Gtk.Align.CENTER)
        self.rebuild_button = Gtk.Button(label="Rebuild", valign=Gtk.Align.CENTER)
        self.rebuild_button.connect("clicked", self._on_rebuild)
        self.rebuild_row.add_suffix(self.spinner)
        self.rebuild_row.add_suffix(self.rebuild_button)
        index_group.add(self.rebuild_row)

    # ---------------------------------------------------------------- actions

    def toast(self, message: str):
        self.toasts.add_toast(Adw.Toast(title=message, timeout=4))

    def _choose_folder(self, _button):
        dialog = Gtk.FileDialog(title="Add folder to index", modal=True)
        dialog.select_folder(self, None, self._folder_chosen)

    def _folder_chosen(self, dialog, result):
        try:
            folder = dialog.select_folder_finish(result)
        except GLib.Error:
            return
        if folder is None:
            return
        path = folder.get_path()
        if not path:
            return
        code, _, err = run_config("add-root", path)
        if code != 0:
            self.toast(err or "Could not add folder")
            return
        self.toast(f"Added {short_path(path)}")
        self.refresh()

    def _on_hidden(self, row, _param):
        if getattr(self, "_loading", False):
            return
        self._set("hidden", "true" if row.get_active() else "false")

    def _on_local(self, row, _param):
        if getattr(self, "_loading", False):
            return
        self._set("oneFileSystem", "true" if row.get_active() else "false")

    def _on_ttl(self, row, _param):
        if getattr(self, "_loading", False):
            return
        index = max(0, min(row.get_selected(), len(TTL_OPTIONS) - 1))
        self._set("ttlSeconds", str(TTL_OPTIONS[index]))

    def _set(self, key: str, value: str):
        code, _, err = run_config("set", key, value)
        if code != 0:
            self.toast(err or "Could not save setting")
            return
        self.refresh()

    def _on_rebuild(self, _button):
        if self.stats.get("running"):
            code, _, err = run_config("stop")
            if code != 0:
                self.toast(err or "Could not stop indexing")
            else:
                self.toast("Stopping index build")
        else:
            code, _, err = run_config("rebuild")
            if code != 0:
                self.toast(err or "Could not start indexing")
        self.refresh_soon()

    def _remove_root(self, path: str):
        code, _, err = run_config("remove-root", path)
        if code != 0:
            self.toast(err or "Could not remove folder")
            return
        self.toast(f"Removed {short_path(path)}")
        self.refresh()

    def _open_root(self, path: str):
        try:
            Gio.AppInfo.launch_default_for_uri(Gio.File.new_for_path(path).get_uri(), None)
        except GLib.Error as error:
            self.toast(str(error))

    # --------------------------------------------------------------- refresh

    def refresh_soon(self):
        GLib.timeout_add(350, self._refresh_once)

    def _refresh_once(self):
        self.refresh()
        return False

    def _tick(self):
        self.refresh()
        return True

    def refresh(self):
        self.config = read_config()
        self.stats = read_stats()
        self._sync_folders()
        self._sync_options()
        self._sync_index()

    def _sync_folders(self):
        roots = [str(path) for path in self.config.get("roots", []) if path]
        key = tuple(roots)
        if key == self._roots_key:
            return
        self._roots_key = key

        for row in self._root_rows:
            self.folders_group.remove(row)
        self._root_rows = []

        missing = set(self.stats.get("missingRoots") or [])
        for path in roots:
            row = Adw.ActionRow(title=short_path(path), subtitle=path)
            row.set_subtitle_lines(1)
            if path in missing:
                row.add_css_class("error")
                row.set_subtitle(path + " · missing, skipped")

            open_button = Gtk.Button(icon_name="folder-open-symbolic", valign=Gtk.Align.CENTER)
            open_button.add_css_class("flat")
            open_button.set_tooltip_text("Open in file manager")
            open_button.connect("clicked", lambda _b, p=path: self._open_root(p))

            remove_button = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER)
            remove_button.add_css_class("flat")
            remove_button.set_tooltip_text("Stop indexing this folder")
            remove_button.connect("clicked", lambda _b, p=path: self._remove_root(p))

            row.add_suffix(open_button)
            row.add_suffix(remove_button)
            self.folders_group.add(row)
            self._root_rows.append(row)

    def _sync_options(self):
        self._loading = True
        self.hidden_row.set_active(self.config.get("hidden") is True)
        self.local_row.set_active(self.config.get("oneFileSystem") is not False)
        ttl = int(self.config.get("ttlSeconds") or 300)
        selected = 0
        for index, option in enumerate(TTL_OPTIONS):
            if option <= ttl:
                selected = index
        self.ttl_row.set_selected(selected)
        self._loading = False

    def _sync_index(self):
        running = self.stats.get("running") is True
        started = int(self.stats.get("startedAt") or 0)

        if running:
            elapsed = max(0, int(time.time()) - started) if started else 0
            detail = f"Indexing · {elapsed}s" if elapsed else "Indexing…"
            self.rebuild_row.set_title("Stop indexing")
            self.rebuild_row.set_subtitle(detail)
            self.rebuild_button.set_label("Stop")
            self.spinner.start()
            self.spinner.set_visible(True)
            return

        files = int(self.stats.get("files") or 0)
        if files <= 0:
            detail = "No index yet"
        else:
            detail = (
                f"{format_count(files)} files · "
                f"{format_bytes(self.stats.get('bytes'))} · "
                f"{format_age(self.stats.get('ageSeconds'))}"
            )
        self.rebuild_row.set_title("Rebuild index now")
        self.rebuild_row.set_subtitle(detail)
        self.rebuild_button.set_label("Rebuild")
        self.spinner.stop()
        self.spinner.set_visible(False)

    # -------------------------------------------------------------- keyboard

    def _on_key(self, _controller, keyval, _keycode, _state):
        if keyval == Gdk.KEY_Escape:
            self.close()
            return True
        return False


class SettingsApp(Adw.Application):
    def __init__(self):
        super().__init__(
            application_id="io.github.iamkuo.FuzzySearch",
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )
        self.window = None

    def do_activate(self):
        if self.window is None:
            self.window = SettingsWindow(self)
            self.window.connect("destroy", self._on_destroy)
        self.window.present()

    def _on_destroy(self, _window):
        self.window = None


if __name__ == "__main__":
    SettingsApp().run(None)
