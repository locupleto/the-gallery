#!/usr/bin/env python3
"""learn-menu.py -- gallery.learn's menu source and panel renderer.

Bridges the host's IPC-only menu actions (see the Plugin-Contract.md
"exec/open/ipc" note) with a menu that needs to carry a *choice* -- which
cheat sheet was picked -- through to the panel. There is no channel for
that in the manifest.gallery.menu action schema itself, so the "show"
action below writes the choice to a small state file instead, then asks
the host to (re)open this plugin's panel, which reads that file back on
its own next render. See the fuller note above action_show().

Actions (argv[1]):
  list             One JSON object per line -- lib/menu.lua's "command"
                   menu source reads this as the chooser's items. One
                   item per *.md file directly under SHEETS, plus a
                   "Tiler keys" item first if Tiler-Keys.md exists.
  show <path>      Record <path> as the current sheet and (re)open the
                   gallery.learn panel so it re-renders it.
  render           Print the current sheet, converted to a small HTML
                   fragment, to stdout. Called by index.html's own
                   gallery.exec on every panel load.

Only ever reads *.md files under SHEETS; never writes into the vault.
Stdlib only (json, html, re, subprocess) -- no third-party deps, per the
host's own policy for plugin-bundled scripts.
"""
import html
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
VAULT = os.environ.get(
    "OBSIDIAN_VAULT",
    HOME + "/Library/Mobile Documents/iCloud~md~obsidian/Documents/ObsidianVault",
)
SHEETS = os.environ.get("LEARN_SHEETS", VAULT + "/Cheat-Sheets")

STATE_DIR = HOME + "/.config/gallery/state"
CURRENT_PATH = os.path.join(STATE_DIR, "learn-current")
# Overridable so tests/learn_test.lua can exercise action_show() without
# shelling out to the real ~/bin/gallery -- calling that from inside a
# Lua chunk a live Hammerspoon is currently executing would deadlock
# (its close/open need that same Hammerspoon's IPC port serviced, which
# doesn't happen until the chunk that spawned this subprocess returns).
GALLERY_BIN = os.environ.get("LEARN_GALLERY_BIN", HOME + "/bin/gallery")

# This script's own directory. Computed at runtime (not hardcoded) so the
# "show" action embedded in each menu item always names wherever this
# copy of the plugin actually lives -- the installed location under
# ~/.config/gallery/plugins/gallery.learn once install.sh has copied it
# there, matching lib/panel.lua's own entry.dir resolution.
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
PYTHON3 = "/usr/bin/python3"

TILER_KEYS_NAME = "Tiler-Keys.md"


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def strip_frontmatter(text):
    """Drop a leading YAML frontmatter block (--- ... ---), if present."""
    if text.startswith("---\n") or text.startswith("---\r\n"):
        m = re.match(r"^---\r?\n.*?\r?\n---\r?\n", text, re.DOTALL)
        if m:
            return text[m.end():]
    return text


def sheet_title_and_subtext(path):
    """(title, subText) for one sheet -- title is the first H1, or the
    filename if there is none; subText is the first non-empty,
    non-heading line in the body. Lines inside fenced code blocks are
    skipped for both -- several of these sheets show markdown/bash
    snippets containing "# Heading"-looking lines, which are not real
    headings."""
    text = read_text(path)
    if text is None:
        return os.path.splitext(os.path.basename(path))[0], ""

    body = strip_frontmatter(text)
    prose_lines = list(_non_code_lines(body.splitlines()))

    title = None
    for line in prose_lines:
        m = re.match(r"^#\s+(.+?)\s*$", line)
        if m:
            title = m.group(1).strip()
            break
    if title is None:
        title = os.path.splitext(os.path.basename(path))[0]

    subtext = ""
    for line in prose_lines:
        stripped = line.strip()
        if not stripped:
            continue
        if re.match(r"^#{1,6}\s+", stripped):
            continue
        subtext = stripped
        break

    return title, subtext


def _non_code_lines(lines):
    """Yield lines that are not inside a ``` fenced code block."""
    in_code = False
    for line in lines:
        if re.match(r"^\s*```", line):
            in_code = not in_code
            continue
        if not in_code:
            yield line


def show_action_for(path):
    return {
        "type": "exec",
        "command": PYTHON3,
        "args": [os.path.join(PLUGIN_DIR, "learn-menu.py"), "show", path],
    }


def action_list():
    if not os.path.isdir(SHEETS):
        print(json.dumps({
            "text": "(no Cheat-Sheets folder found)",
            "subText": SHEETS,
            "action": {"type": "open", "url": "about:blank"},
        }))
        return

    tiler_path = os.path.join(SHEETS, TILER_KEYS_NAME)
    if os.path.isfile(tiler_path):
        print(json.dumps({
            "text": "Tiler keys",
            "subText": "generated key sheet -- left Option is super",
            "action": show_action_for(tiler_path),
        }))

    try:
        names = sorted(
            f for f in os.listdir(SHEETS)
            if f.endswith(".md") and not f.startswith(".") and f != TILER_KEYS_NAME
        )
    except OSError:
        names = []

    for name in names:
        path = os.path.join(SHEETS, name)
        title, subtext = sheet_title_and_subtext(path)
        print(json.dumps({
            "text": title,
            "subText": subtext,
            "action": show_action_for(path),
        }))


def action_show(path):
    # Recording the choice here (rather than passing it through the menu
    # action, which the host restricts to exec/open/ipc) is the whole
    # reason this script exists as a stateful helper rather than a plain
    # `{"type":"ipc","verb":"open","id":"gallery.learn"}` action -- see
    # the module docstring.
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(CURRENT_PATH, "w", encoding="utf-8") as f:
        f.write(path + "\n")

    # lib/panel.lua's M.open no-ops ("already open: <id>") if the panel's
    # webview already exists, without reloading its page -- so if the
    # panel is already open, index.html's on-load gallery.exec("render")
    # (which is what would pick up the new learn-current) would never
    # run again. Closing first forces the next open to create a fresh
    # webview. Closing when nothing is open is a harmless no-op
    # ("not open: <id>"), so this is unconditional rather than checking
    # state first.
    subprocess.run([GALLERY_BIN, "close", "gallery.learn"],
                    capture_output=True, text=True, check=False)
    subprocess.run([GALLERY_BIN, "open", "gallery.learn"],
                    capture_output=True, text=True, check=False)


def render_message(message):
    return '<div class="learn-empty">' + html.escape(message) + "</div>"


def action_render():
    current = read_text(CURRENT_PATH)
    path = current.strip() if current else None
    if not path or not os.path.isfile(path):
        print(render_message("No cheat sheet selected yet -- pick one from the Learn menu."))
        return

    md = read_text(path)
    if md is None:
        print(render_message("Could not read " + path))
        return

    print(markdown_to_html(md))


# ---------------------------------------------------------------------
# markdown -> HTML: a small stdlib-only subset converter. Handles
# headings, paragraphs, bullet and numbered lists, fenced code blocks,
# inline code, bold, italics, links, and tables (rendered as plain rows,
# not a <table> grid -- see the module docstring for why: the source
# markdown here is a handful of personal cheat sheets, not general
# markdown, so a full CommonMark table implementation is not worth it).
# ---------------------------------------------------------------------

_HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
_BULLET_RE = re.compile(r"^\s*[-*+]\s+(.*)$")
_NUMBER_RE = re.compile(r"^\s*\d+\.\s+(.*)$")
_FENCE_RE = re.compile(r"^\s*```")
_TABLE_SEP_RE = re.compile(r"^\s*\|?[\s:|-]+\|?\s*$")

_INLINE_CODE_RE = re.compile(r"`([^`]+)`")
_BOLD_RE = re.compile(r"\*\*(.+?)\*\*")
_ITALIC_RE = re.compile(r"(?<!\*)\*(?!\*)([^*]+?)\*(?!\*)|(?<!_)_([^_]+?)_(?!_)")
_LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")


def inline_html(text):
    """Apply inline-only markdown transforms to one line of already
    plain text. Order matters: inline code is stashed out first (behind
    NUL-delimited placeholders) so bold/italic/link markup inside a code
    span is never touched, then restored, already-escaped, at the end."""
    text = html.escape(text, quote=False)

    codes = []

    def stash_code(m):
        codes.append(m.group(1))
        return "\x00CODE%d\x00" % (len(codes) - 1)

    text = _INLINE_CODE_RE.sub(stash_code, text)
    text = _BOLD_RE.sub(r"<strong>\1</strong>", text)

    def italic_sub(m):
        inner = m.group(1) if m.group(1) is not None else m.group(2)
        return "<em>%s</em>" % inner

    text = _ITALIC_RE.sub(italic_sub, text)

    def link_sub(m):
        label, url = m.group(1), m.group(2)
        return '<a href="%s">%s</a>' % (html.escape(url, quote=True), label or url)

    text = _LINK_RE.sub(link_sub, text)

    for i, code in enumerate(codes):
        text = text.replace("\x00CODE%d\x00" % i, "<code>%s</code>" % code)
    return text


def split_table_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def markdown_to_html(md):
    md = strip_frontmatter(md)
    lines = md.splitlines()

    out = ['<div class="learn-doc">']
    i = 0
    n = len(lines)
    list_stack = None  # "ul" or "ol" -- the currently-open list, if any
    para_buf = []

    def flush_para():
        if para_buf:
            joined = " ".join(l.strip() for l in para_buf if l.strip())
            if joined:
                out.append("<p>%s</p>" % inline_html(joined))
            para_buf.clear()

    def close_list():
        nonlocal list_stack
        if list_stack:
            out.append("</%s>" % list_stack)
            list_stack = None

    while i < n:
        line = lines[i]

        if _FENCE_RE.match(line):
            flush_para()
            close_list()
            i += 1
            code_lines = []
            while i < n and not _FENCE_RE.match(lines[i]):
                code_lines.append(lines[i])
                i += 1
            i += 1  # skip the closing fence
            out.append("<pre><code>%s</code></pre>" % html.escape("\n".join(code_lines)))
            continue

        heading_m = _HEADING_RE.match(line)
        if heading_m:
            flush_para()
            close_list()
            level = len(heading_m.group(1))
            out.append("<h%d>%s</h%d>" % (level, inline_html(heading_m.group(2)), level))
            i += 1
            continue

        if not line.strip():
            flush_para()
            close_list()
            i += 1
            continue

        bullet_m = _BULLET_RE.match(line)
        number_m = _NUMBER_RE.match(line) if not bullet_m else None
        if bullet_m or number_m:
            flush_para()
            wanted = "ul" if bullet_m else "ol"
            if list_stack and list_stack != wanted:
                close_list()
            if not list_stack:
                out.append("<%s>" % wanted)
                list_stack = wanted
            content = (bullet_m or number_m).group(1)
            out.append("<li>%s</li>" % inline_html(content))
            i += 1
            continue

        # A real table needs a header row followed by a separator row
        # (CommonMark's table syntax) -- just testing "|" in line would
        # also fire on an ordinary sentence that happens to contain a
        # literal "|" (e.g. inside inline code, as one of these cheat
        # sheets does), which is not a table at all.
        is_table_start = (
            "|" in line
            and not _TABLE_SEP_RE.match(line)
            and i + 1 < n
            and _TABLE_SEP_RE.match(lines[i + 1])
            and "|" in lines[i + 1]
        )
        if is_table_start:
            flush_para()
            close_list()
            out.append('<div class="learn-table">')
            while i < n and "|" in lines[i]:
                if _TABLE_SEP_RE.match(lines[i]):
                    i += 1
                    continue
                cells = split_table_row(lines[i])
                row = "".join('<span class="learn-cell">%s</span>' % inline_html(c) for c in cells)
                out.append('<div class="learn-row">' + row + "</div>")
                i += 1
            out.append("</div>")
            continue

        para_buf.append(line)
        i += 1

    flush_para()
    close_list()
    out.append("</div>")
    return "\n".join(out)


def main(argv):
    if len(argv) < 2:
        print("usage: learn-menu.py list|show <path>|render", file=sys.stderr)
        return 1

    action = argv[1]
    if action == "list":
        action_list()
    elif action == "show":
        if len(argv) < 3:
            print("usage: learn-menu.py show <path>", file=sys.stderr)
            return 1
        action_show(argv[2])
    elif action == "render":
        action_render()
    else:
        print("unknown action: " + action, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
