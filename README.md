# Omarchy Fuzzy Menu

A personal clone of Omarchy's `Super+Space` menu with fuzzy search, inline file
results, frecency ranking, starred files, and an in-menu file actions submenu.

- **Fuzzy menu search** across every Omarchy menu command and installed app.
- **Inline file results** under a `FILES` section, powered by `fd` and `fzf`.
- **Frecency ranking** so files you open most often rise to the top, with a
  30-day half-life.
- **Starred files** always rank above other files, but never above Omarchy
  menu options.
- **File actions** open in the same menu: default app, editor, file manager,
  terminal, copy path, and star/unstar.
- **A settings app** — a normal GTK4/libadwaita window (not an overlay) to
  add or remove indexed folders, include hidden files, keep the walk on local
  filesystems, tune the refresh interval, and rebuild or stop the index.

## Requirements

- Omarchy 4.0.4 or newer, with the Quickshell menu plugin architecture.
- `fd`, `fzf`, `jq`, `flock` (`util-linux`), `nautilus`, `wl-copy`, and
  `xdg-terminal-exec`. These ship with or are already used by a normal Omarchy
  install.
- `python-gobject`, `gtk4`, and `libadwaita` for the settings window.

## Install

```bash
git clone https://github.com/iamkuo/omarchy-fuzzy-search.git \
  ~/.config/omarchy/plugins/ryankuo.menu

omarchy plugin validate ~/.config/omarchy/plugins/ryankuo.menu
omarchy-shell shell rescanPlugins
omarchy plugin enable ryankuo.menu
```

The plugin declares `clonedFrom: omarchy.menu`, so Omarchy routes existing
`omarchy.menu` calls and the `Super+Space` binding to this clone.

Add the settings entry to your user menu so it is reachable by typing
`Super+Space` → `search settings`:

```jsonc
// ~/.config/omarchy/extensions/omarchy-menu.jsonc
"search-settings": {
  "icon": "󰍉",
  "label": "Search Settings",
  "aliases": ["fuzzy", "file-search", "search-folders", "index-folders"],
  "description": "Choose which folders Super+Space file search indexes",
  "action": "omarchy-shell shell summon ryankuo.menu '{\"mode\":\"settings\"}'"
}
```

Because this is a clone, upstream Omarchy menu changes are not merged
automatically. Diff against the built-in plugin after Omarchy updates if you
want to pick up new menu features.

## Usage

- Press `Super+Space` and type. Menu commands and apps are fuzzy-matched.
- Files that match appear below all Omarchy options in the `FILES` section.
- Press `Enter`, `Right`, or click a file row to open its actions menu:
  - Open
  - Open in Editor
  - Reveal in File Manager
  - Open Terminal Here
  - Copy Path
  - Star / Unstar
- Press `Esc`, `Left`, or `Backspace` in the actions menu to go back to the
  file results.
- Starred files only appear when they match the query, and always sort above
  other files.

## Settings

Open it from `Super+Space` by typing `search settings`, or directly:

```bash
omarchy-shell shell summon ryankuo.menu '{"mode":"settings"}'
```

The menu closes and the settings window opens as its own app (a normal
top-level window, not a layer-shell overlay), so it can be focused, tiled or
floated, and never stays above other windows.

The settings window is still part of this plugin: it ships in the same folder,
uses the same `bin/omarchy-search-config` and config file, and is only
reachable through the plugin's menu entry or `summon` route. Disabling
`ryankuo.menu` removes both. `omarchy plugin update` updates it with the rest of
the plugin.

Optional Hyprland rule to float and centre it like a dialog (class is stable):

```lua
-- ~/.config/hypr/windows.lua
o.window({ class = "^(io.github.iamkuo.FuzzySearch)$" }, { float = true })
```

In the window:

- **Indexed folders** — one row per root. The folder button opens it in the
  file manager; the trash button stops indexing it. **Add Folder…** opens a
  folder picker.
- **Include hidden files** — index dotfiles and hidden directories.
- **Stay on local filesystem** — skip network and FUSE mounts. Keep this on for
  BTRFS speed; turning it off can make a rebuild walk Google Drive or SSHFS.
- **Refresh index** — the automatic rebuild interval (1 minute to 1 hour).
- **Rebuild index now** — force a rebuild; while one is running the row becomes
  **Stop indexing** with a spinner and elapsed time.

Esc closes the window. Every settings change rebuilds the index in a detached
process, so closing the window does not stop a build: reopening shows the
running build, then the finished stats.

The configuration is `~/.config/omarchy/fuzzy-search.json`:

```json
{
  "version": 1,
  "roots": ["~", "~/Projects"],
  "excludes": ["node_modules", ".git", "target", "build"],
  "hidden": false,
  "oneFileSystem": true,
  "ttlSeconds": 300,
  "maxResults": 200000,
  "maxCandidates": 500,
  "threads": 0
}
```

`threads: 0` uses every core. `maxCandidates` caps how many `fzf` hits are
merged before ranking. The file is created with defaults on first open; a
pre-existing `~/.config/omarchy/search-roots` list is imported once.

## State and performance

- Search state: `~/.local/state/omarchy/search.json`
- File index cache: `~/.cache/omarchy-search/files`
- The index refreshes on the interval from settings (five minutes by default).
- On BTRFS, the index uses `fd --one-file-system`, so it stays on the local
  filesystem and skips rclone/FUSE mounts such as `~/Drive`.
- Roots come from the settings view (or the JSON file). Adding network mounts
  makes indexing much slower; the local-filesystem switch protects against it.
- Delete `~/.local/state/omarchy/search.json` to reset usage counts and stars.

## Attribution and license

`Menu.qml` and `MenuModel.js` are derived from Omarchy's built-in
`omarchy.menu` plugin, which is MIT licensed.

MIT License. See [LICENSE](LICENSE).
