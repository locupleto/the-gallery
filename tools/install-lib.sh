#!/usr/bin/env bash
#
# install-lib.sh -- helpers shared by install.sh and tiler/install.sh. Sourced,
# never executed. Written for bash 3.2 (macOS /bin/bash): no mapfile, no
# associative arrays.
#
# The contract: every pre-existing user file the installers replace or edit is
# backed up once, and every file they write is recorded, so --uninstall can put
# the Mac back as it was.
#
#   install manifest   ~/.config/gallery/state/install-manifest.tsv, one line
#                      per file written: <path> TAB <sha256 written> [TAB <backup>]
#   whole files        gl_install_file / gl_uninstall_file (replaced files)
#   edited in place    gl_backup_once, then a marked edit (init.lua block,
#                      include lines, btop/superfile keys)
#
# The caller sets GL_DRY=1 for a dry run and may set GL_TAG (message prefix).
# Nothing here touches the real system beyond the files it is handed.

GL_CONFIG_DIR="${GL_CONFIG_DIR:-${HOME}/.config/gallery}"
GL_STATE_DIR="${GL_CONFIG_DIR}/state"
GL_MANIFEST="${GL_STATE_DIR}/install-manifest.tsv"
GL_DRY="${GL_DRY:-0}"
GL_TAG="${GL_TAG:-[gallery]}"
GL_TS="${GL_TS:-$(date +%Y%m%d-%H%M%S)}"

# What an uninstall did, printed by gl_summary: newline-separated lines per
# outcome.
GL_S_RESTORED=""
GL_S_REMOVED=""
GL_S_KEPT=""

gl_say() { echo "${GL_TAG} $*"; }
gl_warn() { echo "${GL_TAG} $*" >&2; }

gl_note() {
  # gl_note restored|removed|kept <text>
  local kind="$1"
  shift
  case "${kind}" in
    restored) GL_S_RESTORED="${GL_S_RESTORED}${GL_S_RESTORED:+
}$*" ;;
    removed)  GL_S_REMOVED="${GL_S_REMOVED}${GL_S_REMOVED:+
}$*" ;;
    kept)     GL_S_KEPT="${GL_S_KEPT}${GL_S_KEPT:+
}$*" ;;
  esac
}

gl_summary() {
  echo "${GL_TAG} summary"
  if [ -n "${GL_S_RESTORED}" ]; then
    echo "${GL_TAG}   restored:"
    printf '%s\n' "${GL_S_RESTORED}" | sed "s|^|${GL_TAG}     |"
  fi
  if [ -n "${GL_S_REMOVED}" ]; then
    echo "${GL_TAG}   removed:"
    printf '%s\n' "${GL_S_REMOVED}" | sed "s|^|${GL_TAG}     |"
  fi
  if [ -n "${GL_S_KEPT}" ]; then
    echo "${GL_TAG}   kept:"
    printf '%s\n' "${GL_S_KEPT}" | sed "s|^|${GL_TAG}     |"
  fi
  [ -n "${GL_S_RESTORED}${GL_S_REMOVED}${GL_S_KEPT}" ] || echo "${GL_TAG}   nothing to do"
}

# gl_sha <file> -- sha256 of a file (empty output if unreadable).
gl_sha() {
  shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
}

# gl_exists <path> -- present, including as a dangling symlink.
gl_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# --- manifest ----------------------------------------------------------------

# gl_manifest_field <path> <n> -- field n (2 = hash, 3 = backup) of a path's line.
gl_manifest_field() {
  [ -f "${GL_MANIFEST}" ] || return 0
  awk -F'\t' -v p="$1" -v n="$2" '$1 == p { print $n; exit }' "${GL_MANIFEST}"
}

gl_manifest_paths() {
  [ -f "${GL_MANIFEST}" ] || return 0
  cut -f1 "${GL_MANIFEST}"
}

# gl_manifest_set <path> <hash> [backup] -- add or update a line in place (the
# backup column of an existing line is kept unless one is given). No-op in a
# dry run.
gl_manifest_set() {
  [ "${GL_DRY}" -eq 1 ] && return 0
  local bak tmp
  bak="${3:-$(gl_manifest_field "$1" 3)}"
  mkdir -p "${GL_STATE_DIR}"
  tmp="$(mktemp "${GL_STATE_DIR}/.manifest.XXXXXX")"
  touch "${GL_MANIFEST}"
  P="$1" H="$2" B="${bak}" awk -F'\t' '
    function line() { return ENVIRON["P"] "\t" ENVIRON["H"] (ENVIRON["B"] != "" ? "\t" ENVIRON["B"] : "") }
    $1 == ENVIRON["P"] { if (!done) print line(); done = 1; next }
    { print }
    END { if (!done) print line() }
  ' "${GL_MANIFEST}" > "${tmp}"
  mv -f "${tmp}" "${GL_MANIFEST}"
}

gl_manifest_del() {
  [ "${GL_DRY}" -eq 1 ] && return 0
  [ -f "${GL_MANIFEST}" ] || return 0
  local tmp
  tmp="$(mktemp "${GL_STATE_DIR}/.manifest.XXXXXX")"
  P="$1" awk -F'\t' '$1 != ENVIRON["P"]' "${GL_MANIFEST}" > "${tmp}"
  mv -f "${tmp}" "${GL_MANIFEST}"
  [ -s "${GL_MANIFEST}" ] || rm -f "${GL_MANIFEST}"
}

# --- whole files -------------------------------------------------------------

# gl_unique <base> -- <base> if free, else <base>.<n> until one is.
gl_unique() {
  local cand="$1" n=1
  while gl_exists "${cand}"; do
    cand="$1.${n}"
    n=$((n + 1))
  done
  printf '%s' "${cand}"
}

# gl_backup_path <dest> -- where the user's original goes: <dest>.gallery-bak,
# or <dest>.gallery-bak.<timestamp> if that is taken.
gl_backup_path() {
  if gl_exists "$1.gallery-bak"; then
    gl_unique "$1.gallery-bak.${GL_TS}"
  else
    printf '%s' "$1.gallery-bak"
  fi
}

# gl_recognisable <file> -- looks like an earlier Gallery version of a file:
# one of its first lines names the Gallery or tiler/. Older installs have no
# manifest, so this is how they are told from a user's own file.
gl_recognisable() {
  # Files the Gallery names after itself (~/bin/gallery-*, anything under
  # ~/.config/gallery) only need to mention it; files with generic names
  # (yabairc, skhdrc, learn, ...) need one of the shipped header markers, so a
  # user's own config that merely says "gallery" is backed up, not overwritten.
  case "$1" in
    */gallery*|"${GL_CONFIG_DIR}"/*)
      head -n 40 "$1" 2>/dev/null | grep -qiE 'gallery|tiler/' ;;
    *)
      head -n 40 "$1" 2>/dev/null | grep -qE 'the-gallery|The Gallery|tiler/' ;;
  esac
}

# gl_put <src> <dest> <mode> -- the actual copy, with the manifest entry.
gl_put() {
  mkdir -p "$(dirname "$2")"
  install -m "$3" "$1" "$2"
  gl_manifest_set "$2" "$(gl_sha "$2")"
}

# gl_install_file <src> <dest> <mode> [previous-ok] -- install a file the
# Gallery owns without ever losing one of the user's:
#   absent                          install, record
#   identical to src                record only
#   recorded, unchanged since       it is ours: overwrite
#   recorded, changed since         the user edited it: keep a copy as
#                                   <dest>.gallery-edited.<timestamp>, overwrite
#   not recorded, looks Gallery     an older install (no manifest then): save an
#                                   edited copy to be safe, overwrite
#   not recorded, anything else     the user's own: move to <dest>.gallery-bak,
#                                   install
# previous-ok=1 treats an unrecorded file as an older Gallery file regardless
# of content (for formats that cannot carry a header).
gl_install_file() {
  local src="$1" dest="$2" mode="$3" prev_ok="${4:-0}"
  local src_hash dest_hash man_hash bak edited
  src_hash="$(gl_sha "${src}")"
  man_hash="$(gl_manifest_field "${dest}" 2)"

  if ! gl_exists "${dest}"; then
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) would install ${dest}"
    else
      gl_put "${src}" "${dest}" "${mode}"
    fi
    return 0
  fi

  dest_hash="$(gl_sha "${dest}")"
  if [ -n "${dest_hash}" ] && [ "${dest_hash}" = "${src_hash}" ]; then
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) ${dest} is already current"
    else
      gl_manifest_set "${dest}" "${dest_hash}"
    fi
    return 0
  fi

  if [ -n "${man_hash}" ] && [ "${dest_hash}" = "${man_hash}" ]; then
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) would overwrite ${dest} (Gallery's own copy, unmodified)"
    else
      gl_put "${src}" "${dest}" "${mode}"
    fi
    return 0
  fi

  if [ -n "${man_hash}" ] || [ "${prev_ok}" = 1 ] || { [ -f "${dest}" ] && gl_recognisable "${dest}"; }; then
    # Ours, but not what we last wrote (edited, or an older version).
    edited="$(gl_unique "${dest}.gallery-edited.${GL_TS}")"
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) would copy ${dest} to ${edited}, then overwrite it (it differs from what the Gallery wrote)"
      return 0
    fi
    cp -p "${dest}" "${edited}"
    if [ -n "${man_hash}" ]; then
      gl_warn "${dest} was edited since it was installed; your version is kept as ${edited}"
      gl_warn "  (put lasting changes in a local override file, e.g. ~/.config/skhd/local.skhd or ~/.config/yabai/yabairc.local)"
    else
      gl_say "${dest} is an older Gallery version; a copy is kept as ${edited}"
    fi
    gl_put "${src}" "${dest}" "${mode}"
    return 0
  fi

  # Not recorded and not recognisable: the user's own file.
  bak="$(gl_backup_path "${dest}")"
  if [ "${GL_DRY}" -eq 1 ]; then
    gl_say "(dry-run) ${dest} exists, user file: would back it up to ${bak}"
    return 0
  fi
  mv "${dest}" "${bak}"
  gl_say "backed up your ${dest} to ${bak} (restored on uninstall)"
  gl_put "${src}" "${dest}" "${mode}"
  gl_manifest_set "${dest}" "$(gl_sha "${dest}")" "${bak}"
}

# gl_uninstall_file <dest> -- undo gl_install_file: remove the file if it is
# still what we wrote (otherwise keep it as .gallery-edited), then put the
# user's original back. Files with no manifest entry are not ours and are left.
gl_uninstall_file() {
  local dest="$1" man_hash bak edited
  man_hash="$(gl_manifest_field "${dest}" 2)"
  if [ -z "${man_hash}" ]; then
    if gl_exists "${dest}"; then
      gl_say "${dest}: not installed by the Gallery, leaving it"
      gl_note kept "${dest} (not installed by the Gallery)"
    fi
    return 0
  fi
  bak="$(gl_manifest_field "${dest}" 3)"
  [ -n "${bak}" ] || bak="${dest}.gallery-bak"

  if gl_exists "${dest}"; then
    if [ "$(gl_sha "${dest}")" = "${man_hash}" ]; then
      if [ "${GL_DRY}" -eq 1 ]; then
        gl_say "(dry-run) would remove ${dest}"
      else
        rm -f "${dest}"
      fi
      # (A restored original is reported below instead.)
      gl_exists "${bak}" || gl_note removed "${dest}"
    else
      edited="$(gl_unique "${dest}.gallery-edited.${GL_TS}")"
      if [ "${GL_DRY}" -eq 1 ]; then
        gl_say "(dry-run) ${dest} was edited: would move it to ${edited}"
      else
        mv "${dest}" "${edited}"
        gl_warn "${dest} was edited since install; kept as ${edited}"
      fi
      gl_note kept "${edited} (your edited copy of ${dest})"
    fi
  fi

  if gl_exists "${bak}"; then
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) would restore ${bak} to ${dest}"
    else
      mv "${bak}" "${dest}"
    fi
    gl_note restored "${dest} (your original)"
  fi
  gl_manifest_del "${dest}"
}

# --- files edited in place ---------------------------------------------------

# gl_backup_once <file> -- before the first edit of an existing file, keep a
# copy as <file>.gallery-bak (same name bin/gallery's console_backup_once uses).
# Never overwritten afterwards.
gl_backup_once() {
  [ -f "$1" ] || return 0
  [ -e "$1.gallery-bak" ] && return 0
  if [ "${GL_DRY}" -eq 1 ]; then
    gl_say "(dry-run) would back up $1 to $1.gallery-bak"
  else
    cp -p "$1" "$1.gallery-bak"
    gl_say "backed up $1 to $1.gallery-bak before editing it"
  fi
}

# gl_same_text <a> <b> -- equal apart from trailing newlines.
gl_same_text() {
  [ "$(cat "$1")" = "$(cat "$2")" ]
}

# gl_block_has <file> -- the file holds a complete gallery:begin/end block.
gl_block_has() {
  [ -f "$1" ] && grep -qx -- '-- gallery:begin' "$1" && grep -qx -- '-- gallery:end' "$1"
}

# gl_block_replace <file> <block> -- swap the marked block for <block> (which
# carries its own markers). Prints nothing; the caller decides whether needed.
gl_block_replace() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  BLOCK="$2" awk '
    skip { if ($0 == "-- gallery:end") skip = 0; next }
    $0 == "-- gallery:begin" { print ENVIRON["BLOCK"]; skip = 1; next }
    { print }
  ' "$1" > "${tmp}"
  cat "${tmp}" > "$1"
  rm -f "${tmp}"
}

# gl_block_strip <file> -- remove the marked block and the one blank line the
# installer put in front of it.
gl_block_strip() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  awk '
    function flush() { while (nb > 0) { print ""; nb-- } }
    skip { if ($0 == "-- gallery:end") skip = 0; next }
    $0 == "-- gallery:begin" { skip = 1; if (nb > 0) nb--; next }
    /^$/ { nb++; next }
    { flush(); print }
    END { flush() }
  ' "$1" > "${tmp}"
  cat "${tmp}" > "$1"
  rm -f "${tmp}"
}

# gl_line_remove <file> <line> -- drop every line equal to <line>.
gl_line_remove() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  LINE="$2" awk '$0 != ENVIRON["LINE"]' "$1" > "${tmp}"
  cat "${tmp}" > "$1"
  rm -f "${tmp}"
}

# gl_rmdir_empty <dir>... -- remove each directory only if it is empty.
gl_rmdir_empty() {
  local d
  for d in "$@"; do
    [ -d "${d}" ] || continue
    [ -n "$(ls -A "${d}" 2>/dev/null)" ] && continue
    if [ "${GL_DRY}" -eq 1 ]; then
      gl_say "(dry-run) would remove empty directory ${d}"
    else
      rmdir "${d}" 2>/dev/null || true
    fi
  done
}

# gl_finish_edit <file> <created-by-us> -- after stripping our edit out of a
# file: if a .gallery-bak exists and the file now reads the same, put the
# backup back byte for byte; if the file is empty and we created it, delete it.
# Otherwise leave it (and the backup) and say so.
gl_finish_edit() {
  local file="$1" created="${2:-0}"
  [ -f "${file}" ] || return 0
  if [ -e "${file}.gallery-bak" ]; then
    if gl_same_text "${file}" "${file}.gallery-bak"; then
      cp -p "${file}.gallery-bak" "${file}"
      rm -f "${file}.gallery-bak"
      gl_note restored "${file}"
    else
      gl_note kept "${file} (edited since the backup; backup kept as ${file}.gallery-bak)"
    fi
  elif [ "${created}" = 1 ] && [ -z "$(tr -d '[:space:]' < "${file}")" ]; then
    rm -f "${file}"
    gl_note removed "${file} (created by the Gallery)"
  else
    gl_note restored "${file} (Gallery lines removed)"
  fi
}

# --- directories synced with rsync --delete ----------------------------------

# gl_rsync_delete <src/> <dest/> -- `rsync -a --delete`, but first move aside
# any file the sync would delete (something a user dropped into a Gallery-owned
# directory, or a file an older Gallery shipped) into
# ~/.config/gallery/backup/<timestamp>/, and say so.
gl_rsync_delete() {
  local src="$1" dest="$2" gone bdir n=0
  if [ -d "${dest}" ]; then
    bdir="${GL_CONFIG_DIR}/backup/${GL_TS}/${dest#"${HOME}"/}"
    while IFS= read -r gone; do
      [ -n "${gone}" ] || continue
      case "${gone}" in
        */) continue ;;
        *__pycache__*|*.pyc|*.DS_Store) continue ;;
      esac
      n=$((n + 1))
      if [ "${GL_DRY}" -eq 1 ]; then
        gl_say "(dry-run) would back up ${dest}${gone} to ${bdir}/${gone} before the sync deletes it"
      else
        mkdir -p "$(dirname "${bdir}/${gone}")"
        cp -p "${dest}${gone}" "${bdir}/${gone}"
      fi
    done <<EOF
$(rsync -a --delete --dry-run --itemize-changes "${src}" "${dest}" 2>/dev/null | sed -n -E 's/^\*deleting +//p')
EOF
    if [ "${n}" -gt 0 ] && [ "${GL_DRY}" -eq 0 ]; then
      gl_say "${n} file(s) in ${dest} are not part of the Gallery; copied to ${bdir} before the sync"
    fi
  fi
  if [ "${GL_DRY}" -eq 1 ]; then
    gl_say "(dry-run) rsync -a --delete ${src} ${dest}"
  else
    rsync -a --delete "${src}" "${dest}"
  fi
}
