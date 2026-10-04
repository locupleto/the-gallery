# Tiling

## Settings and rules: `~/.config/yabai/yabairc.local`

Plain `sh`, sourced by `yabairc` after the shipped settings, so a value set
here wins. The installer never creates it; start from the template if the
user has none (the checkout's `tiler/yabairc.local.example` lists every
shipped setting with its value: `layout`, `window_placement`, `split_ratio`,
`auto_balance`, `window_gap` and the four paddings (all 8), the mouse
settings).

```sh
yabai -m config window_gap 12
yabai -m config top_padding 12
yabai -m rule --add label=never-tile-spotify app="^Spotify$" manage=off
```

Every rule needs a `label`, so running the file again replaces it instead of
adding a duplicate.

## Applying without a restart

Never restart yabai to apply a change without the user's go-ahead: it loses
the layout of every Desktop. Run the same lines live, and keep them in the
file so they survive the next start:

```sh
yabai -m config window_gap 12     # takes effect at once
sh ~/.config/yabai/yabairc.local  # or re-run the whole file
yabai -m rule --apply             # apply rules to windows already open
```

## Which Desktop an app lives on: `gallery home`

`~/.config/yabai/rules.local` holds one `space=N` rule per app. It is written
by `gallery home save` from the current layout, so the user arranges the
windows and then saves; do not hand-edit it (the next save overwrites it).

```sh
gallery home show                # window -> Space map, and the saved rules
gallery home save --dry-run      # preview
gallery home save                # write rules.local and apply it
gallery home apply               # re-apply it live
```

- Only apps with a window open when saving get a home; an app that is not
  running loses its old rule. Say so before saving.
- Terminals and the browser roam (`--roam A,B` changes the list). An app on
  several Desktops is pinned per window by title, which breaks when the title
  changes.
- `home save` also records each Desktop's tile shape in
  `~/.config/yabai/home-layout.json`. After a login the Gallery applies the
  rules once more at the first quiet moment, then rebuilds the shapes where
  the Desktop holds the same apps (logged in
  `~/.config/gallery/gallery-home.log`).
- A Desktop showing a different wallpaper from the rest: `gallery bg apply`
  syncs them all (the after-login pass does it too).
- Keep other rules in `yabairc.local`, not `rules.local`.

## Floating

super + t floats or tiles the focused window. System dialogs and utilities
float by design. To keep an app out of tiling for good, a `manage=off` rule
in `yabairc.local`, then `yabai -m rule --apply`.

## The focus outline

```sh
gallery borders status
gallery borders width 8          # 1-12, default 5
gallery borders bright on        # mix the colour toward bright_foreground
```

The colour comes from the theme (`hyprland_active_border`, else `accent`).

## Repairs

super + shift + b balances the tiles; ctrl + super + r rebuilds the current
Space's tree. `gallery ghosts` lists windows yabai cannot see (born while the
screen was locked) and `gallery ghosts fix` relaunches their app.
