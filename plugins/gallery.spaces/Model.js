// Model.js -- pure data transforms for gallery.spaces. No DOM access here;
// index.html owns rendering, this file owns turning the raw payload pushed
// by gallery.data.subscribe("spaces", cb) -- {spaces, windows}, straight
// from `yabai -m query --spaces` and `yabai -m query --windows` per
// Gallery.spoon/lib/bridge.lua's pollSpaces() -- into a shape a template
// can walk without doing any of its own grouping, joining, or sorting.
//
// window.gallery.data.subscribe pushes {error: "..."} on failure (see
// bridge.lua's pushYabaiError); buildViewModel passes that straight
// through as the view-model's own .error so index.html has one place to
// check.
(function (global) {
  "use strict";

  // yabai window records carry "space", the owning space's numeric
  // `index` (NOT its `id` -- confirmed against a live `yabai -m query
  // --windows`/`--spaces` pair: a window with "space":8 belongs to the
  // space whose "index" is 8, which on this machine has "id":12; joining
  // on `id` instead silently drops every window on a space whose id and
  // index diverge, which by construction is every space past the very
  // first few created -- so joining must go through "index").
  function windowsBySpaceIndex(windows) {
    var map = {};
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i];
      var key = w.space;
      if (!map[key]) {
        map[key] = [];
      }
      map[key].push(w);
    }
    return map;
  }

  function toWindowView(w) {
    return {
      id: w.id,
      app: w.app || "",
      title: w.title || "",
      hasFocus: !!w["has-focus"],
      isFloating: !!w["is-floating"],
      isMinimized: !!w["is-minimized"],
      isHidden: !!w["is-hidden"]
    };
  }

  function stackIndexOf(w) {
    return typeof w["stack-index"] === "number" ? w["stack-index"] : 0;
  }

  // Attaches each space's windows (sorted by stack-index, then window id
  // for a stable tie-break) and narrows every field index.html actually
  // reads. Pure: does not mutate the arrays it is given.
  function attachWindows(spaces, windows) {
    var bySpace = windowsBySpaceIndex(windows);
    return spaces.map(function (s) {
      var ws = (bySpace[s.index] || []).slice();
      ws.sort(function (a, b) {
        var d = stackIndexOf(a) - stackIndexOf(b);
        if (d !== 0) {
          return d;
        }
        return (a.id || 0) - (b.id || 0);
      });
      return {
        id: s.id,
        index: s.index,
        display: s.display,
        label: s.label || "",
        hasFocus: !!s["has-focus"],
        isVisible: !!s["is-visible"],
        windows: ws.map(toWindowView)
      };
    });
  }

  // Groups already window-attached spaces by their `display` field (the
  // display's numeric id, per `yabai -m query --displays`), ordered by
  // that id ascending, with spaces inside each group ordered by their own
  // `index` ascending. displayLabel is a 1-based ordinal ("Display 1",
  // "Display 2", ...) over that same ascending order, since the `spaces`
  // feed alone (no --displays query) carries no human label to show.
  function groupByDisplay(spacesWithWindows) {
    var byDisplay = {};
    var displayIds = [];
    spacesWithWindows.forEach(function (s) {
      var d = s.display;
      if (!Object.prototype.hasOwnProperty.call(byDisplay, d)) {
        byDisplay[d] = [];
        displayIds.push(d);
      }
      byDisplay[d].push(s);
    });
    displayIds.sort(function (a, b) { return a - b; });

    return displayIds.map(function (displayId, i) {
      var group = byDisplay[displayId].slice().sort(function (a, b) {
        return a.index - b.index;
      });
      return {
        displayId: displayId,
        displayLabel: "Display " + (i + 1),
        spaces: group
      };
    });
  }

  // buildViewModel(data) -> { error, displays }
  //   data   -- whatever gallery.data.subscribe("spaces", cb) pushed:
  //             either {spaces:[...], windows:[...]} or {error:"..."}.
  //   error  -- data.error, or a message this function made up for a
  //             shape it does not recognise; null when spaces/windows
  //             parsed cleanly (an empty array is not an error).
  //   displays -- [] on error, else the groupByDisplay() result above.
  function buildViewModel(data) {
    if (!data) {
      return { error: "no data", displays: [] };
    }
    if (data.error) {
      return { error: String(data.error), displays: [] };
    }
    var spaces = Array.isArray(data.spaces) ? data.spaces : null;
    var windows = Array.isArray(data.windows) ? data.windows : null;
    if (!spaces || !windows) {
      return { error: "unexpected spaces payload shape", displays: [] };
    }
    return { error: null, displays: groupByDisplay(attachWindows(spaces, windows)) };
  }

  // Truncates to at most maxLen characters, replacing the last character
  // with an ellipsis when longer; never returns a string longer than
  // maxLen. null/undefined become "".
  function truncate(value, maxLen) {
    var str = value == null ? "" : String(value);
    if (str.length <= maxLen) {
      return str;
    }
    if (maxLen <= 1) {
      return str.slice(0, maxLen);
    }
    return str.slice(0, maxLen - 1) + "…";
  }

  global.GallerySpacesModel = {
    buildViewModel: buildViewModel,
    truncate: truncate
  };
})(window);
