# Keys

skhd reads `~/.config/skhd/skhdrc`, which binds nothing itself and loads, in
this order:

1. `~/.config/skhd/local.skhd`: the user's keys. **The only file to edit.**
2. `~/.config/skhd/tiler.skhd`: the tiler's keys (Gallery-owned).
3. `~/.config/skhd/gallery.skhd`: the Gallery's keys (Gallery-owned).

skhd keeps the first definition of a hotkey and silently drops later ones, so
a key bound in `local.skhd` replaces the shipped one and a new key is added.

## Syntax

`lalt` is left Option ("super"); right Option is deliberately unbound so it
still types `@ | [ ] { }` on non-US layouts. Examples:

```sh
## open Spotify
lalt - p : open -a Spotify
## a second coding agent
shift + ctrl + lalt - g : "$HOME/bin/gallery" agent open gemini
```

- A `## ` line directly above a binding describes it and puts it on the key
  sheet under "Your keys"; a `# --- section ---` header files following keys
  under another heading.
- skhd has no unbind: switch a shipped key off by binding it to a no-op,
  `lalt + ctrl - 0 : true`.
- Before choosing a key, see what is taken:
  `grep -hE '^[a-z].* : ' ~/.config/skhd/tiler.skhd ~/.config/skhd/gallery.skhd`.
  `lalt` plus `b c f h j k l m o r s t w`, `return`, `tab`, `space`, the
  arrows and `1`-`9` are mostly used by the tiler.
- Letters follow the keyboard layout (on AZERTY or Dvorak they move); see
  "Keyboard layouts" in `docs/CUSTOMIZING.md` for hex keycodes.

## Applying

skhd reloads `local.skhd` by itself when it changes. If the file did not
exist when skhd started, run `skhd --reload` once. Then regenerate the key
sheet (super + shift + space):

```sh
~/.config/skhd/learn install
```

Check a binding works with `skhd --observe` (prints keys as pressed; Ctrl-C
to stop). If keys do nothing while a terminal is in front, Secure Keyboard
Entry is on in that terminal.
