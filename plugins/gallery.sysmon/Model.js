// Model.js -- pure functions for gallery.sysmon: parse the crystal_sampler
// metrics.json snapshot (pushed over gallery.data.subscribe("metrics", cb))
// and `ps` output (from gallery.exec, the fallback for top processes) into a
// plain view model, plus number formatting. No DOM access anywhere in this
// file -- index.html owns rendering, this file owns turning raw data into
// display-ready values so the two can be tested/reasoned about separately.
//
// Structure (Model.js of pure functions + index.html that only renders) and
// two helpers below (compactBytes, percentOf) are modelled on the Omarchy
// community plugin eipi10.cpu-ram's Model.js:
//   https://github.com/forbidden-game/omarchy-plugins/blob/main/plugins/eipi10.cpu-ram/Model.js
// That repo's plugins/eipi10.cpu-ram/LICENSE and the repo-root LICENSE are
// both MIT (repo root: "Copyright (c) 2026 Xiezhao Pan"; plugin: "Copyright
// (c) 2026 eipi10"), confirmed by fetching both files directly, so reuse
// here is permitted. eipi10's Model.js parses Linux /proc/stat,
// /proc/meminfo, /proc/loadavg and a `ps -eo comm=,%cpu=,%mem=` dump by
// hand, because Quickshell hands it raw proc text; crystal_sampler's
// metrics.json already carries parsed CPU/mem/swap/load numbers, so that
// parsing has no counterpart here -- only the two output-formatting
// helpers (byte compaction, percent clamping) are reused, ported verbatim
// (var-based ES5 style kept to match) rather than proc-string parsing.

(function (root) {
  "use strict";

  var STALE_AFTER_SECONDS = 5;

  // ---- reused verbatim from eipi10.cpu-ram Model.js (MIT) -----------------

  // Compact byte string with one decimal place above 1K: 812B, 1.2K, 34M, 6.5G.
  function compactBytes(bytes) {
    var n = Number(bytes);
    if (!isFinite(n) || n < 0) n = 0;
    if (n < 1024) return Math.round(n) + "B";
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + "K";
    if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + "M";
    return (n / (1024 * 1024 * 1024)).toFixed(1) + "G";
  }

  function percentOf(used, total) {
    if (!total || total <= 0) return 0;
    return Math.max(0, Math.min(100, (used / total) * 100));
  }

  // ---- gallery.sysmon's own helpers ---------------------------------------

  function round1(n) {
    var v = Number(n);
    if (!isFinite(v)) return 0;
    return Math.round(v * 10) / 10;
  }

  function formatPercent(n) {
    return round1(n).toFixed(1) + "%";
  }

  // metrics.json amounts are KiB (see crystal_sampler); convert to bytes so
  // compactBytes's thresholds (1024-based) apply directly.
  function kibToBytes(kib) {
    var n = Number(kib);
    if (!isFinite(n) || n < 0) return 0;
    return n * 1024;
  }

  function formatLoad(load) {
    if (!Array.isArray(load) || load.length === 0) return "n/a";
    return load
      .map(function (v) {
        var n = Number(v);
        return isFinite(n) ? n.toFixed(2) : "0.00";
      })
      .join("  ");
  }

  // now/timestamp both in whole seconds (Date.now()/1000 vs snapshot's unix
  // "timestamp" field). Returns { stale, ageSeconds }; a missing/invalid
  // timestamp is treated as stale so the UI fails loud rather than silent.
  function staleness(timestampSeconds, nowMs) {
    var ts = Number(timestampSeconds);
    if (!isFinite(ts) || ts <= 0) {
      return { stale: true, ageSeconds: null };
    }
    var ageSeconds = (nowMs || Date.now()) / 1000 - ts;
    return { stale: ageSeconds > STALE_AFTER_SECONDS, ageSeconds: ageSeconds };
  }

  // Parse one crystal_sampler metrics.json snapshot (already-decoded object,
  // as handed to the "metrics" subscribe callback) into a view model. Never
  // throws: a malformed/error snapshot (bridge.lua pushes {error: "..."} when
  // the file is unreadable) yields { ok: false, error }.
  function parseSnapshot(raw, nowMs) {
    if (!raw || typeof raw !== "object") {
      return { ok: false, error: "no data" };
    }
    if (raw.error) {
      return { ok: false, error: String(raw.error) };
    }

    var cpuCores = Array.isArray(raw.cpu) ? raw.cpu.map(function (v) { return round1(v); }) : [];
    var cpuOverall = 0;
    if (cpuCores.length > 0) {
      var sum = cpuCores.reduce(function (a, b) { return a + b; }, 0);
      cpuOverall = round1(sum / cpuCores.length);
    }

    var mem = raw.mem || {};
    var memTotalBytes = kibToBytes(mem.total_kib);
    var memUsedBytes = kibToBytes(mem.used_kib);

    var swap = raw.swap || {};
    var swapTotalBytes = kibToBytes(swap.total_kib);
    var swapUsedBytes = kibToBytes(swap.used_kib);

    var st = staleness(raw.timestamp, nowMs);

    return {
      ok: true,
      error: null,
      stale: st.stale,
      ageSeconds: st.ageSeconds,
      timeLabel: typeof raw.time === "string" ? raw.time : null,
      cpuOverall: cpuOverall,
      cpuCores: cpuCores,
      mem: {
        usedBytes: memUsedBytes,
        totalBytes: memTotalBytes,
        percent: round1(percentOf(memUsedBytes, memTotalBytes))
      },
      swap: {
        usedBytes: swapUsedBytes,
        totalBytes: swapTotalBytes,
        percent: round1(percentOf(swapUsedBytes, swapTotalBytes))
      },
      load: Array.isArray(raw.load) ? raw.load : [],
      tasks: typeof raw.tasks === "number" ? raw.tasks : null,
      threads: typeof raw.threads === "number" ? raw.threads : null,
      temps: raw.temps && typeof raw.temps === "object" ? raw.temps : null,
      fans: Array.isArray(raw.fans) ? raw.fans : null
    };
  }

  // Parse `/bin/ps -Aro pid,%cpu,%mem,comm` stdout (BSD ps, macOS): a header
  // line "PID %CPU %MEM COMM" followed by data rows already sorted by -%cpu
  // ("-Aro" keeps ps's default sort, which is descending %cpu on macOS's
  // ps(1)). Column order is fixed (unlike eipi10's Linux `ps -eo
  // comm=,%cpu=,%mem=`, which puts comm first), so this parser is written
  // for that order rather than reusing eipi10's regex verbatim; comm is
  // matched greedily to the end of the line since -o comm on macOS can
  // include a full path with no spaces, but stay defensive anyway.
  function parseTopProcesses(raw, limit) {
    var max = limit || 8;
    var out = [];
    var lines = String(raw || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();
      if (line.length === 0) continue;
      if (/^PID\s+%CPU\s+%MEM\s+COMM$/i.test(line)) continue; // header row
      var m = line.match(/^(\d+)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(.+)$/);
      if (!m) continue;
      out.push({
        pid: parseInt(m[1], 10),
        cpu: parseFloat(m[2]),
        mem: parseFloat(m[3]),
        comm: m[4].trim()
      });
      if (out.length >= max) break;
    }
    return out;
  }

  // Extract the "up ..." portion of macOS `/usr/bin/uptime` output, e.g.
  // "14:32  up 2 days, 21:32, 3 users, load averages: 7.98 6.97 7.90" ->
  // "2 days, 21:32". metrics.json carries no uptime field (confirmed by
  // reading a live ~/tmp/metrics.json snapshot), so index.html gets this via
  // gallery.exec("/usr/bin/uptime", []) instead, on the same timer as the ps
  // fallback poll.
  function parseUptime(raw) {
    var s = String(raw || "");
    var m = s.match(/up\s+(.+?),\s+\d+\s+users?,/);
    if (m) return m[1].trim();
    // Fall back to everything between "up" and the next comma-users clause
    // being absent (e.g. unusual locales) -- better a slightly rough string
    // than nothing.
    m = s.match(/up\s+(.+)$/);
    return m ? m[1].replace(/,\s*load averages:.*$/i, "").trim() : null;
  }

  var Model = {
    STALE_AFTER_SECONDS: STALE_AFTER_SECONDS,
    compactBytes: compactBytes,
    percentOf: percentOf,
    formatPercent: formatPercent,
    formatLoad: formatLoad,
    staleness: staleness,
    parseSnapshot: parseSnapshot,
    parseTopProcesses: parseTopProcesses,
    parseUptime: parseUptime
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = Model;
  } else {
    root.SysmonModel = Model;
  }
})(typeof window !== "undefined" ? window : this);
