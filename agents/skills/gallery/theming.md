# Themes and wallpapers

## Switching

```sh
gallery theme list               # marks the current and light themes
gallery theme set <name>
gallery theme next
gallery theme render             # re-run the renderers only (no hooks)
gallery theme offload <name>     # free a theme's disk on this Mac; its copy stays elsewhere
gallery theme restore <name>     # bring it back
gallery theme offloaded          # what is offloaded here
```

super + shift + ctrl + space opens the picker; `ctrl-x` twice there offloads
the highlighted theme. Offload refuses the current theme and any theme with
no copy elsewhere (only installer-vendored themes and themes claimed by a
hook in `~/.config/gallery/hooks/theme-offload.d/` have one; see
docs/THEMES.md "Offloading a theme"). Never delete a theme folder by hand to
free space: offload it. A theme change recolours the
terminals, the focus outline, the wallpaper, btop and superfile together.

## A new or changed theme

A theme is a directory under `~/.config/gallery/themes/` with a
`colors.toml`; there is no registry. Omarchy themes work as they are (only
`colors.toml` and `backgrounds/` are used).

Never edit a shipped theme in place: an update copies its `colors.toml` back.
Copy it to a new name and change the copy:

```sh
cp -R ~/.config/gallery/themes/tokyo-night ~/.config/gallery/themes/my-night
$EDITOR ~/.config/gallery/themes/my-night/colors.toml
gallery theme set my-night
```

`colors.toml` is flat TOML; `background`, `foreground` and `accent` matter
most, the rest are derived when missing. `~/.config/gallery/bin/render-theme.py
--print` shows the resolved colours without writing anything. Light themes
declare `mode = "light"`. The full key table is in `docs/THEMES.md`.

## Wallpapers

Each theme's wallpapers are the files in its `backgrounds/` directory.

```sh
gallery bg list [theme]          # marks the active one
gallery bg set <file> [theme]
gallery bg next | prev
gallery bg restore               # the user's wallpaper from before the Gallery
```

A left/right pair for two displays is two files with the same stem,
`<stem>.left.<ext>` and `<stem>.right.<ext>`. It is one entry in `bg list`
(shown as `<stem>.left.<ext> (+ right)`), `bg set` takes either half or the
bare stem, and `next`/`prev` step over it as a unit. Leftmost display gets
LEFT, the next RIGHT (further ones RIGHT too); one display gets LEFT. A lone
`.left`/`.right` file is just an image.

To add one, copy an image into the theme's `backgrounds/` (a user's own
theme, or a shipped one: added files survive updates).

## Theming another app: a hook

After `gallery theme set` and `theme next`, every executable in
`~/.config/gallery/hooks/theme-set.d/` runs in name order as
`hook <theme-name>`. The current colours are in
`~/.config/gallery/state/theme.sh` (shell exports) and `theme.json`. The
shipped hooks are `10-`, `20-` and `30-`; name a new one e.g.
`50-myapp.sh` and `chmod +x` it.
