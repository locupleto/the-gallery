# akshar.radio-atlas 0.1.9 -- macOS patch notes

Radio Atlas is an Omarchy (Arch/Hyprland) plugin. Its QML and player logic
are untouched; every file below is a same-named replacement for one of the
plugin's own helper scripts, swapping Linux-only tools/APIs for their macOS
equivalents. See each file's own header comment for the specific upstream
line(s) it replaces and why.

## Homebrew formulae required

```
brew install bash mpv socat jq
```

- `bash` -- macOS ships bash 3.2 (Apple stopped bundling GPLv3 bash);
  `radio-fetch`'s `load_bases()` uses `mapfile`, a bash 4+ builtin, so
  that one script's shebang points at `/opt/homebrew/bin/bash` instead of
  `/usr/bin/env bash`. Every other helper only needs bash 3.2 and keeps
  the upstream `#!/usr/bin/env bash` shebang unchanged.
- `mpv` -- the actual player; not installed by default. Installing it
  pulls in a large dependency tree, which can include an **upgrade of the
  Homebrew `python@3.14` keg** (here 3.14.6 -> 3.14.7) even when that keg
  is `brew pin`ned. Venvs built on Homebrew's python survive this when
  their `bin/python3.14` is a symlink through `/opt/homebrew/opt/python@3.14`
  (the "current version" symlink Homebrew repoints on upgrade) rather than
  a pinned Cellar path: a same-minor-version patch bump preserves the
  stdlib/C-extension ABI. Re-pin `python@3.14` afterwards if you rely on
  the pin as a guard against an *unintended* bump.
- `socat` and `jq` -- were already installed; the plugin's own bridge
  (`radio-sandbox`) and every JSON-shelling helper use them respectively.
- `flock` and `shuf` -- also already present via Homebrew's `flock`
  formula and `coreutils`; both are plain PATH lookups, no patch needed,
  just documented here since upstream's own install docs call out
  `util-linux`/`coreutils` as dependencies.

## Files in this patch and what changed

### `radio-window`
Upstream uses `hyprctl eval` to install a Hyprland Lua window rule
(float, center, fixed size). Hyprland doesn't exist on macOS, and
Gallery's QML host already centers/sizes the panel window itself.
`RadioAtlas.qml`'s `windowSetupProcess` doesn't gate on this script's
exit code, so it's replaced with an `exit 0` no-op.

### `radio-proxy` (Python)
Only `route_is_local()` changed: it shelled out to Linux's `ip -j route
get <ip>` (iproute2, JSON) to catch an address that's "globally routable"
per Python's `ipaddress` module but that this host's own routing table
actually resolves to itself. Replaced with BSD `route -n get <ip>`
(macOS's stock `/sbin/route`), parsing its plain-text `interface:`/
`flags:` lines for `lo0` / `LOCAL` instead of iproute2's JSON `type`/
`dev` fields. Same check, same intent, macOS-native command.

### `radio-sandbox`
Drops the `setpriv --pdeathsig TERM` prefix in front of the socat
bridge (`util-linux`, absent on macOS, no direct BSD substitute for
"die when my parent dies" from a plain CLI). The bridge itself
(`socat TCP4-LISTEN:... UNIX-CONNECT:...`) is unchanged. `pdeathsig` was
upstream's extra safety net in case the direct parent died uncleanly;
`radio-session` (below) already traps EXIT/INT/TERM and explicitly kills
this process's PID, so normal shutdown paths are unaffected.

### `radio-session`
The larger change. Upstream wraps mpv in a `bwrap --unshare-net
--unshare-pid ...` network namespace (only loopback up) so mpv's *only*
route to the internet is back through `radio-sandbox`'s bridge into
`radio-proxy` -- that's the plugin's real network sandbox, and it also
used `setpriv --pdeathsig TERM` to launch the proxy. **bubblewrap does
not exist on macOS**, and there's no way to build an equivalent network
namespace from a plain shell script on Darwin (no user namespaces /
`unshare(2)` exposed to bash). This patch drops both `setpriv` and the
whole `bwrap` wrapper and calls `radio-sandbox` directly.

**Trade-off (the one real security degradation in this patch set):** on
macOS, mpv keeps normal, unrestricted network access. It's still
launched with `http_proxy`/`https_proxy` pointed at the radio-sandbox
bridge, so a well-behaved request still passes through radio-proxy's
public-address/redirect filtering -- but nothing *forces* mpv (or a
library/demuxer it loads) through that proxy the way a kernel network
namespace did upstream. In practice this only matters for a maliciously
crafted stream URL trying to reach a private/local address (SSRF
protection is now advisory, not enforced); ordinary playback of a real
internet radio stream via `https://...` is functionally identical to
upstream.

### `radio-state`
`stat -c '%s'` (GNU coreutils file-size query) doesn't exist on macOS's
BSD `stat` -- one call site, replaced with `stat -f '%z'`. Nothing else
changed; macOS's stock bash 3.2 is fine for this script.

### `radio-fetch`
Four independent changes, documented together in this one file's header:
- Re-execs under Homebrew bash, `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` (see "Homebrew formulae" above --
  `mapfile` needs bash 4).
- `discover_bases()`: upstream's `getent ahostsv4 all.api.radio-browser
  .info` (resolve every A record) and `getent hosts <ip>` (reverse
  lookup to confirm the mirror's hostname) are util-linux/glibc, absent
  on macOS. Replaced with `dig +short A ...` and `dig +short -x <ip>`
  (BIND's `dig`, present on macOS by default) -- same forward-then-
  verify-reverse mirror discovery, same regex filter on the result.
- `request()`: drops `setpriv --pdeathsig TERM` in front of `curl` (see
  radio-sandbox's note) and calls `/usr/bin/curl` explicitly. This Mac
  has Anaconda's curl earlier on `$PATH`; hard-coding the system curl
  avoids picking up a curl build that may not support every flag this
  script relies on (`--max-filesize`, `--proto '=https'`, etc. -- all
  confirmed present in macOS's stock `/usr/bin/curl` 8.7.1).
- `stat -c '%s'` -> `stat -f '%z'`, three call sites (world/country cache
  validation, response size check).

### `radio-player`
Three independent changes:
- `process_start_time()`: `/proc/$pid/stat` field 22 (process start
  time, used by `player_alive()` to detect a stale pidfile pointing at a
  since-reused PID) doesn't exist on macOS. Replaced with `ps -o
  state=,lstart= -p <pid>`, converting the human-readable start
  timestamp to epoch seconds with `date -j -f` so it still satisfies the
  `^[0-9]+$` checks elsewhere in the file unchanged, and still rejects a
  zombie (`Z` state) the way the original's `awk '$3 != "Z"'` filter did.
- `list_outputs()`: upstream calls `pactl -f json list sinks`
  (PipeWire's control CLI). macOS has no PipeWire and no per-app output
  routing mpv could use even if it did. Returns a plain `{"outputs":[]}`
  (success, not an error) so the QML output picker shows "no outputs"
  instead of a failure banner. Consequence: **the audio-output picker
  and AirPlay/RAOP routing are gone** on macOS -- radio always plays
  through the system's current default output device, the same way any
  other Mac app does. `set_output()`/the `--audio-device` mpv flag are
  consequently unreachable in normal use (nothing ever validates against
  a non-empty output list), which is the intended degraded behavior, not
  a bug.
- `play_station()`: `setsid` (util-linux) launches `radio-session`
  detached in its own session/process group so `terminate_tracked_
  player()`'s `kill -- "-$pid"` can reap the whole mpv tree in one shot.
  **`setsid` does not exist on macOS** -- discovered live during testing
  (`radio-player play` failed with "setsid: command not found" until
  this was patched). Replaced with a one-line Perl `POSIX::setsid()` +
  `exec`, which is exactly what GNU `setsid(1)` itself does under the
  hood in this context (no controlling terminal / not already a process
  group leader -> `setsid()` then `execvp()` in place, same PID). Verified
  the resulting mpv process tree is a distinct session/process group and
  that `radio-player stop` reaps mpv + socat + the proxy cleanly.

## What's degraded on macOS (summary)

- **Audio output picker / AirPlay (RAOP) routing**: gone. No PipeWire on
  macOS, so `list_outputs` always reports zero sinks; playback always
  goes to the Mac's current system output device. Not a crash, just the
  picker showing "no outputs."
- **MPRIS / media keys**: gone. Upstream's README describes integration
  with `omarchy.media`/`mpv-mpris` (Linux's MPRIS D-Bus media-key
  standard); macOS has no MPRIS. mpv still runs its own
  `radio-status.lua` script and exposes the same IPC socket this
  plugin's own scripts use (`radio-player status/toggle/next/previous/
  mute/volume`), so in-app controls work identically -- only the
  system-level "media keys on the keyboard" integration is absent, and
  it was never wired into Gallery/macOS to begin with.
- **Network sandboxing of mpv**: advisory, not enforced (see
  `radio-session`'s note above). The SSRF-hardened proxy (`radio-proxy`)
  and its public-address/redirect filtering are fully intact and mpv is
  still pointed at them via `http_proxy`/`https_proxy`; what's missing is
  the kernel-level network namespace (`bwrap --unshare-net`) that forced
  every connection through that proxy on Linux. Ordinary playback is
  unaffected; only a deliberately hostile stream URL trying to reach a
  private/internal address is affected.

## Not patched

`radio-status.lua` (mpv Lua script) and every `.qml`/`.js` file are
unmodified upstream -- they loaded and ran correctly under Gallery's QML
shim as-is. `radio-proxy`'s HTTP/CONNECT proxy logic (header parsing,
CONNECT tunneling, connection-count limiting) is unchanged; only its one
Linux-specific subprocess call was replaced.
