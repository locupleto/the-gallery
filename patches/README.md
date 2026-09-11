# patches/ -- per-plugin macOS overlay

An unmodified, git-cloned Omarchy plugin sometimes ships a file that only
makes sense on Linux (a Quickshell service block that shells out to a
Linux-only CLI, an icon path baked in for Arch's icon theme, a helper
script that assumes `systemctl`, ...). Rather than hand-edit the plugin's
own clone (which `gallery update` would just overwrite on the next pull),
drop a same-named replacement file here and Gallery applies it on top of
the installed copy every time the plugin is installed or updated.

## Layout

```
patches/<plugin-id>/<path/to/file, relative to the plugin's own root>
```

For example, to replace a hypothetical `akshar.radio-atlas` plugin's
`scripts/radio-window` (a Linux-only launcher script) with a macOS no-op
that just exits 0:

```
patches/akshar.radio-atlas/scripts/radio-window
```

The path under `patches/<plugin-id>/` is copied verbatim over the same
path under the installed plugin (`~/.config/gallery/plugins/<plugin-id>/`),
preserving the source file's permission bits (`cp -p`) -- so a patched
script that needs to stay executable just needs its exec bit set in this
repo (`chmod +x patches/<id>/<path>`, `git update-index --chmod=+x
<path>` if git does not pick it up on its own).

A patch file can also be a NEW file the upstream plugin does not ship at
all (e.g. a macOS-only `scripts/radio-window` for a plugin whose manifest
was edited, via a patch to manifest.json itself, to call it) -- there is
no requirement that the target path already exist in the plugin.

## When patches apply

- `install.sh` copies this directory to `~/.config/gallery/patches/`.
- `gallery add <git-url>` applies `~/.config/gallery/patches/<id>/*` (if
  any) right after cloning, before the plugin is scanned/enabled.
- `gallery update [id]` re-applies patches for every git-managed plugin it
  successfully pulls, so a patch always wins over whatever upstream just
  shipped.
- `gallery patch <id>` re-applies a plugin's patches by hand, without
  cloning or pulling anything -- useful right after editing a patch file
  in this repo and re-running `install.sh`, or to recover a plugin file
  that got overwritten some other way.

A plugin with no directory under `patches/` is entirely unaffected --
`gallery add`/`update`/`patch` are all no-ops for it (no message, no
error).

## What a patch is not

This is a dumb file overlay, not a real patch format (no diffing, no
context, no partial-file hunks) -- keep a patched file's provenance
documented in a comment at its top (upstream path, why it needed
replacing, date) since there is nothing else here to record that.

## Example: `akshar.radio-atlas`

[Radio Atlas](https://github.com/AksharP5/omarchy-radio-atlas) (a `qml`-
kind plugin: a rotatable globe of live internet radio) ships several
Linux-only helper scripts -- `hyprctl` window rules, `bubblewrap`/
`setpriv` process sandboxing, `pactl`/PipeWire audio routing, `getent`/
`ip route`, GNU-only `stat`/bash features. `patches/akshar.radio-atlas/`
replaces exactly those helpers with macOS equivalents (BSD `stat`, `dig`,
`ps`+`date`, a Perl `setsid` shim, etc.) while leaving the plugin's QML
and mpv playback logic untouched. See
`patches/akshar.radio-atlas/PATCH-NOTES.md` for the full per-file
breakdown, the Homebrew formulae it needs (`bash mpv socat jq`), and what
is knowingly degraded on macOS (no audio-output picker/AirPlay routing,
no MPRIS media keys, and mpv's network sandboxing becomes advisory
rather than kernel-enforced since bubblewrap has no macOS equivalent).
