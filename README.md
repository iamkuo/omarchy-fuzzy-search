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

## Requirements

- Omarchy 4.0.4 or newer, with the Quickshell menu plugin architecture.
- `fd`, `fzf`, `jq`, `flock` (`util-linux`), `nautilus`, `wl-copy`, and
  `xdg-terminal-exec`. These ship with or are already used by a normal Omarchy
  install.

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

## State and performance

- Search state: `~/.local/state/omarchy/search.json`
- File index cache: `~/.cache/omarchy-search/files`
- The index refreshes every five minutes.
- On BTRFS, the index uses `fd --one-file-system`, so it stays on the local
  filesystem and skips rclone/FUSE mounts such as `~/Drive`.
- Add extra roots in `~/.config/omarchy/search-roots`, one path per line.
  Adding network mounts will make indexing much slower.
- Delete `~/.local/state/omarchy/search.json` to reset usage counts and stars.

## Attribution and license

`Menu.qml` and `MenuModel.js` are derived from Omarchy's built-in
`omarchy.menu` plugin, which is MIT licensed.

MIT License. See [LICENSE](LICENSE).
