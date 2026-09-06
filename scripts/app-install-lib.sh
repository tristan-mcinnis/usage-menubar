#!/usr/bin/env bash
# shellcheck shell=bash
#
# app-install-lib.sh — shared install engine for the house menu-bar apps.
#
# This file is sourced by scripts/install.sh. It is self-contained and
# parameterised entirely through environment variables set by the caller, so
# the SAME file is carried (byte-for-byte) by every menu-bar repo; it has no
# dependency on another house repo and never runs on its own. The caller owns:
#
#   APP_NAME        display/bundle name, e.g. "Memory"
#   EXEC_NAME       main executable, e.g. "memory-bar"
#   BUNDLE_ID       CFBundleIdentifier, e.g. "com.tristan.memory-menubar"
#   ROOT            repo root (defaults to ../ from this file)
#
# Behaviour is controlled by these INSTALL_* variables (defaults shown):
#
#   INSTALL_CMD            install | rollback | list-backups
#   INSTALL_BUILD          1 to run scripts/build-app.sh, 0 to skip
#   INSTALL_LAUNCH         1 to `open` after install, 0 to leave it closed
#   INSTALL_NO_LOGIN_ITEM  1 to skip login-item (re)registration
#   INSTALL_ALLOW_SIGNING_CHANGE  1 to allow replacing a properly-signed app with
#                          a different signing identity (default 0 = refuse)
#   INSTALL_ROLLBACK_ID    a specific backup id; empty = most recent
#   INSTALL_DEST           override destination (default /Applications/$APP_NAME.app)
#   INSTALL_BACKUP_ROOT    override backup root (default <dest dir>/.$APP_NAME-backups)
#   INSTALL_DIST_APP       override candidate bundle (default $ROOT/dist/$APP_NAME.app)
#
# Safety contract:
#   - The candidate is verified (codesign + plist id / executable / icon /
#     LSUIElement) BEFORE the destination is touched.
#   - The previous installed app is never `rm`'d before a verified replacement
#     is ready; it is renamed aside atomically and only removed after the new
#     bundle passes post-install verification.
#   - On any publish or post-verify failure the previous app is restored.
#   - A properly-signed installed app is never silently replaced with a
#     different signing identity (ad-hoc, another team, or a different embedded
#     identifier): the install refuses and leaves the destination untouched
#     unless --allow-signing-change is given.
#   - The prior app is preserved OUTSIDE Git as an immutable snapshot (the
#     bundle + a manifest of its hash, codesign provenance and source revision)
#     in the backup root. Snapshots are never auto-pruned.
#   - The whole mutating phase is serialised by a lock, so two concurrent
#     installs cannot corrupt the destination.
#   - Only `--launch` opens the app; install never quits or relaunches a running
#     instance on its own.

set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Operand-tracking state shared between _swap_publish and the EXIT trap so a
# failure anywhere (including a signal) puts the prior app back without ever
# deleting it.
_PRIOR_HELD=0
_PRIOR_PATH=""

log()  { printf '• %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_resolve_config() {
  APP_NAME="${APP_NAME:?APP_NAME must be set}"
  EXEC_NAME="${EXEC_NAME:?EXEC_NAME must be set}"
  BUNDLE_ID="${BUNDLE_ID:?BUNDLE_ID must be set}"

  # Normalise the destination path and its parent (the install volume), which
  # is where staging, the named-aside copy and the lock all live so that the
  # publish step is an atomic rename on the same filesystem.
  DIST_APP="${INSTALL_DIST_APP:-$ROOT/dist/$APP_NAME.app}"
  APP_DEST="${INSTALL_DEST:-/Applications/$APP_NAME.app}"
  APP_DEST="${APP_DEST%/}"
  if [[ -z "$APP_DEST" || "$APP_DEST" == "." || "$APP_DEST" == "/" ]]; then
    die "refusing an empty or root install destination"
  fi
  DEST_DIR="$(dirname "$APP_DEST")"
  BACKUP_ROOT="${INSTALL_BACKUP_ROOT:-$DEST_DIR/.$APP_NAME-backups}"

  INSTALL_CMD="${INSTALL_CMD:-install}"
  INSTALL_BUILD="${INSTALL_BUILD:-1}"
  INSTALL_LAUNCH="${INSTALL_LAUNCH:-0}"
  INSTALL_NO_LOGIN_ITEM="${INSTALL_NO_LOGIN_ITEM:-0}"
  INSTALL_ALLOW_SIGNING_CHANGE="${INSTALL_ALLOW_SIGNING_CHANGE:-0}"
  INSTALL_ROLLBACK_ID="${INSTALL_ROLLBACK_ID:-}"

  LOCK_DIR="${LOCK_DIR:-$DEST_DIR/.$APP_NAME.install.lock}"
}

# ---------------------------------------------------------------------------
# Value / verification helpers
# ---------------------------------------------------------------------------

# Print one raw plist value for KEY from FILE, or exit non-zero if it is absent.
_plist_value() {
  local key="$1" pl="$2"
  plutil -extract "$key" raw -o - "$pl" 2>/dev/null
}

# SHA-256 of an app bundle, taken over a tar stream so directories hash too.
_app_hash() {
  local app="$1"
  tar -cf - -C "$(dirname "$app")" "$(basename "$app")" 2>/dev/null \
    | shasum -a 256 2>/dev/null | awk '{print $1}'
}

# Canonical signing identity of a bundle. A real (Developer ID / Apple
# Development) signature is NOT 'Signature=...'; codesign prints 'Signature size=...'
# and carries an Authority chain plus a real TeamIdentifier, so identity is
# classified by whether codesign -d succeeded (rc) and whether it was explicitly
# ad-hoc. 'unsigned' falls back to codesign -d failing. The result is
# 'adhoc', 'unsigned', or 'real:<authority>:<team>:<identifier>'.
_codesign_summary() {
  local app="$1" out sig team auth iden rc
  out="$(codesign -d -vvv "$app" 2>&1)" && rc=0 || rc=$?
  sig="$(printf '%s\n' "$out" | grep -m1 '^Signature=' | cut -d= -f2- || true)"
  team="$(printf '%s\n' "$out" | grep -m1 '^TeamIdentifier=' | cut -d= -f2- || true)"
  auth="$(printf '%s\n' "$out" | grep -m1 '^Authority=' | cut -d= -f2- || true)"
  iden="$(printf '%s\n' "$out" | grep -m1 '^Identifier=' | cut -d= -f2- || true)"
  if [[ "$sig" == "adhoc" ]]; then printf 'adhoc'; return 0; fi
  if [[ "$rc" -ne 0 ]]; then printf 'unsigned'; return 0; fi
  # codesign -d succeeded and it is not explicit ad-hoc: a real signing identity,
  # carried by its Authority chain and TeamIdentifier.
  printf 'real:%s:%s:%s' "${auth:-?}" "${team:-?}" "${iden:-?}"
}

# Structural + signing verification of a bundle candidate. Anything hard fails
# here because it is checked BEFORE the destination is mutated; Gatekeeper
# (spctl) is deliberately not part of this because a personal Apple Development
# / ad-hoc build is not notarized and that is expected.
_verify_bundle() {
  local app="$1" bid exn ui exe sig_ident
  [[ -d "$app" ]] || { warn "bundle missing: $app"; return 1; }

  exe="$app/Contents/MacOS/$EXEC_NAME"
  [[ -x "$exe" ]] || { warn "executable missing/not executable: $exe"; return 1; }
  [[ -f "$app/Contents/Resources/AppIcon.icns" ]] \
    || { warn "icon missing: $app/Contents/Resources/AppIcon.icns"; return 1; }

  [[ -f "$app/Contents/Info.plist" ]] || { warn "no Info.plist: $app/Contents/Info.plist"; return 1; }
  plutil -lint "$app/Contents/Info.plist" >/dev/null 2>&1 \
    || { warn "Info.plist does not lint: $app/Contents/Info.plist"; return 1; }

  bid="$( _plist_value CFBundleIdentifier "$app/Contents/Info.plist" || true )"
  exn="$( _plist_value CFBundleExecutable "$app/Contents/Info.plist" || true )"
  ui="$(  _plist_value LSUIElement "$app/Contents/Info.plist" || true )"

  [[ "$bid" == "$BUNDLE_ID" ]] || { warn "bundle id is '${bid:-<missing>}' (want '$BUNDLE_ID')"; return 1; }
  [[ "$exn" == "$EXEC_NAME" ]] || { warn "CFBundleExecutable is '${exn:-<missing>}' (want '$EXEC_NAME')"; return 1; }
  [[ "$ui" == "true" ]] || { warn "LSUIElement is '${ui:-<missing>}' (want true)"; return 1; }

  # The embedded codesign Identifier must match the expected bundle id too, so a
  # bundle signed under a different name is never installed even if its plist
  # was edited to agree. codesign -d writes to stderr, so 2>&1 is required; an
  # absent or mismatched identifier is a hard failure, never accepted.
  sig_ident="$(codesign -d -vvv "$app" 2>&1 | sed -n 's/^Identifier=//p' | head -1 || true)"
  [[ "$sig_ident" == "$BUNDLE_ID" ]] \
    || { warn "codesign Identifier is '${sig_ident:-<missing>}' (want '$BUNDLE_ID')"; return 1; }

  codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
    || { warn "codesign verification failed for $app"; return 1; }
  return 0
}

# ---------------------------------------------------------------------------
# Locking (mkdir is monotonic and available everywhere; flock is not on macOS)
# ---------------------------------------------------------------------------

_acquire_lock() {
  [[ -n "$LOCK_DIR" ]] || die "lock dir not resolved"
  mkdir -p "$DEST_DIR"
  local pidfile="$LOCK_DIR/pid" p
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$pidfile"
    return 0
  fi
  # A lock is held. Never steal it: an automatic reclaim of a stale lock can
  # race with a concurrent installer doing the same and lose both. Refuse with a
  # clear instruction so the operator decides, and only ever release our own.
  p="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
    die "another install is already running (lock $LOCK_DIR, pid $p). Wait for it to finish, then retry."
  fi
  die "a stale install lock exists at $LOCK_DIR (holder pid '${p:-?}' is not running). If no install is in progress, remove it with: rm -rf \"$LOCK_DIR\"  and then retry."
}

_release_lock() {
  local p
  [[ -n "${LOCK_DIR:-}" ]] || return 0
  [[ -f "$LOCK_DIR/pid" ]] || return 0
  p="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  # Only remove the lock if we own it (pidfile carries our pid), so we never
  # delete a lock another concurrent install is holding.
  if [[ "$p" == "$$" ]]; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}

# Restore a held prior app back to the destination. On success it clears the
# held flag; on failure it leaves the prior copy in place (never deletes it) and
# returns non-zero so the caller can say so truthfully.
_restore_prior() {
  if [[ "${_PRIOR_HELD:-0}" == "1" && -n "${_PRIOR_PATH:-}" && -d "$_PRIOR_PATH" ]]; then
    if mv "$_PRIOR_PATH" "$APP_DEST" 2>/dev/null; then
      _PRIOR_HELD=0; _PRIOR_PATH=""; return 0
    fi
    warn "could not restore the prior app; it is preserved at $_PRIOR_PATH"
    return 1
  fi
  return 0
}

# Final cleanup, set as an EXIT trap so a failure anywhere in the mutating phase
# (including a signal, via the INT/TERM/HUP traps that exit us) never leaks the
# lock or loses the last good copy. It NEVER deletes the aside copy (.prior); if
# the operation did not complete it puts that copy back (restore, not remove).
_final_cleanup() {
  if [[ -n "${DEST_DIR:-}" && -n "${APP_NAME:-}" ]]; then
    local prior="${_PRIOR_PATH:-$DEST_DIR/.$APP_NAME.prior.$$}"
    if [[ "${_PRIOR_HELD:-0}" == "1" && -e "$prior" ]]; then
      local broken="$DEST_DIR/.$APP_NAME.broken.$$"
      if [[ -e "$APP_DEST" ]]; then
        mv "$APP_DEST" "$broken" 2>/dev/null || true
      fi
      # `_restore_prior` may return non-zero on a restore fault; the trap must
      # still continue to clean stage/broken copies and release the lock.
      _restore_prior || true
    fi
    rm -rf "$DEST_DIR/.$APP_NAME.staging.$$" "$DEST_DIR/.$APP_NAME.broken.$$" 2>/dev/null || true
  fi
  _release_lock
}

# ---------------------------------------------------------------------------
# Snapshot persistence (outside Git; immutable; never auto-pruned)
# ---------------------------------------------------------------------------

# Copy PRIOR_APP into the backup root under a timestamped id and write a
# manifest of its hash, codesign provenance and source revision. Emits the
# snapshot dir on success.
_commit_snapshot() {
  local app="$1" id ts sdir bid h sign
  mkdir -p "$BACKUP_ROOT"
  ts="$(date +%Y%m%dT%H%M%S)"
  id="${APP_NAME}-${ts}-$$"
  sdir="$BACKUP_ROOT/$id"
  mkdir -p "$sdir"
  if ! cp -Rp "$app" "$sdir/app"; then
    rm -rf "$sdir" 2>/dev/null || true
    return 1
  fi
  # A snapshot is only worth keeping if it is a verifiable signed bundle.
  if ! _verify_bundle "$sdir/app"; then
    rm -rf "$sdir" 2>/dev/null || true
    warn "snapshot copy failed verification; it was not kept"
    return 1
  fi
  h="$( _app_hash "$sdir/app" )"
  bid="$( _plist_value CFBundleIdentifier "$sdir/app/Contents/Info.plist" 2>/dev/null || echo unknown )"
  sign="$( _codesign_summary "$sdir/app" )"
  {
    echo "app=$APP_NAME"
    echo "snapshot=$id"
    echo "timestamp=$ts"
    echo "installed_to=$APP_DEST"
    echo "bundle_id=$bid"
    echo "signing=$sign"
    # The builder does not embed a source revision, so a snapshot of an
    # installed bundle cannot be attributed to a git revision after the fact.
    # Recording the installer's current HEAD here would claim a provenance the
    # bundle does not actually carry; it stays unknown.
    echo "source_revision=unknown"
    echo "sha256=$h"
    echo "---- codesign -d -vvv ----"
    codesign -d -vvv "$sdir/app" 2>&1 || true
  } > "$sdir/manifest.txt"
  printf '%s\n' "$sdir"
  return 0
}

# ---------------------------------------------------------------------------
# Atomic swap
# ---------------------------------------------------------------------------

# Atomically publish SRC (a verified bundle) over the installed app.
#
#   1. verify SRC before touching the destination
#   2. stage a verified copy on the SAME filesystem as the destination
#   3. rename the existing app aside (never `rm` a live app first)
#   4. atomically rename the staged copy into place
#   5. re-verify the published bundle; on failure restore the prior app
#   6. on success, persist the prior app as an immutable snapshot
#
# On failure it restores the prior app and exits non-zero.
_swap_publish() {
  local src="$1" label="${2:-candidate}"
  local stag prior broken had_prior=0 old_sum new_sum

  _verify_bundle "$src" \
    || die "verification of $label failed before $APP_DEST was touched"

  mkdir -p "$DEST_DIR" "$BACKUP_ROOT"
  [[ -L "$APP_DEST" ]] && die "refusing to install over a symlink at $APP_DEST"

  stag="$DEST_DIR/.$APP_NAME.staging.$$"
  prior="$DEST_DIR/.$APP_NAME.prior.$$"
  broken="$DEST_DIR/.$APP_NAME.broken.$$"
  rm -rf "$stag" "$prior" "$broken"

  ditto "$src" "$stag" || { rm -rf "$stag"; die "could not stage $label on $DEST_DIR"; }
  _verify_bundle "$stag" \
    || { rm -rf "$stag"; die "staged $label failed verification; $APP_DEST untouched"; }

  if [[ -e "$APP_DEST" || -L "$APP_DEST" ]]; then
    had_prior=1
    old_sum="$(_codesign_summary "$APP_DEST")"
    new_sum="$(_codesign_summary "$stag")"
    if [[ "$old_sum" != "$new_sum" ]]; then
      # A properly-signed installed app must not be silently replaced with a
      # different signing identity (ad-hoc, another team, or a different embedded
      # identifier). That is only a deliberate --allow-signing-change override.
      if [[ "$old_sum" == "real:"* && "$INSTALL_ALLOW_SIGNING_CHANGE" != "1" ]]; then
        die "refusing to replace $APP_DEST: signing identity would change from '$old_sum' to '$new_sum' (the installed app is properly signed). Re-run with --allow-signing-change to override."
      fi
      warn "signing identity changes from '$old_sum' to '$new_sum'"
    fi
    # Make and verify a snapshot of the current app BEFORE touching it, so the
    # last good copy is durable before the destination is mutated. If this fails,
    # abort with the destination untouched.
    if ! _commit_snapshot "$APP_DEST"; then
      rm -rf "$stag" "$broken"
      # An unverifiable or absent old install blocks the replacement safely. There
      # is deliberately NO --skip-backup override.
      die "could not make a verified backup of $APP_DEST (the installed app is absent or unverifiable); refusing to replace it. No backup-skip override is available."
    fi
    _PRIOR_HELD=1
    _PRIOR_PATH="$prior"
    mv "$APP_DEST" "$prior" \
      || { rm -rf "$stag" "$broken"; _PRIOR_HELD=0; _PRIOR_PATH=""; die "could not move the current app aside; $APP_DEST untouched"; }
  fi

  if ! mv "$stag" "$APP_DEST"; then
    local restored=0
    if [[ "$had_prior" -eq 1 ]]; then
      _restore_prior || restored=1
    fi
    rm -rf "$stag"
    if [[ "$had_prior" -eq 1 && "$restored" -eq 1 ]]; then
      die "atomic publish of $label failed and the prior app could NOT be restored; it is preserved at $_PRIOR_PATH"
    fi
    die "atomic publish of $label failed; the prior app was restored"
  fi

  if ! _verify_bundle "$APP_DEST"; then
    # The bundle we just put in place failed verification (never the prior live
    # app: that is aside and already snapshotted). Move the broken publish out
    # and put the prior app back verbatim.
    mv "$APP_DEST" "$broken" 2>/dev/null || rm -rf "$broken" "$APP_DEST" 2>/dev/null || true
    local restored=0
    if [[ "$had_prior" -eq 1 ]]; then
      _restore_prior || restored=1
    fi
    rm -rf "$broken" 2>/dev/null || true
    if [[ "$had_prior" -eq 1 && "$restored" -eq 1 ]]; then
      die "post-publish verification of $label failed and the prior app could NOT be restored; it is preserved at $_PRIOR_PATH"
    fi
    if [[ "$had_prior" -eq 1 ]]; then
      die "post-publish verification of $label failed; the prior app was restored"
    fi
    die "post-publish verification of $label failed; there was no prior app to restore"
  fi

  # Success: the verified snapshot is already in the backup root, so drop the
  # aside copy last, never before a verified snapshot exists.
  if [[ "$had_prior" -eq 1 ]]; then
    rm -rf "$prior" 2>/dev/null || true
  fi
  _PRIOR_HELD=0; _PRIOR_PATH=""
  log "Published $label to $APP_DEST"
  return 0
}

# ---------------------------------------------------------------------------
# Login item
# ---------------------------------------------------------------------------

_login_item_exists() {
  local r
  r="$(osascript -e "tell application \"System Events\" to exists login item \"$APP_NAME\"" 2>/dev/null || true)"
  [[ "$r" == "true" ]]
}

_register_login_item() {
  log "Registering $APP_NAME as a login item…"
  local had=0
  _login_item_exists && had=1
  if ! osascript >/dev/null 2>&1 <<OSA
tell application "System Events"
    if exists login item "$APP_NAME" then delete login item "$APP_NAME"
    make login item at end with properties {name:"$APP_NAME", path:"$APP_DEST", hidden:false}
end tell
OSA
  then
    # Never lose the old login item silently. Report the truth and, when a
    # login item existed before, put it back as a best effort.
    warn "the app was installed at $APP_DEST, but its login item could NOT be updated"
    if [[ "$had" -eq 1 ]]; then
      osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events"
    if exists login item "$APP_NAME" then delete login item "$APP_NAME"
    make login item at end with properties {name:"$APP_NAME", path:"$APP_DEST", hidden:false}
end tell
OSA
      warn "the previous login item was re-registered (best effort)"
    fi
    return 1
  fi
  log "  login item registered."
  return 0
}

# ---------------------------------------------------------------------------
# Snapshot listing / rollback
# ---------------------------------------------------------------------------

# High-resolution birth time of a snapshot dir, independent of its name (which
# encodes seconds + PID and so reorders after a PID wrap). macOS records this in
# nanoseconds (stat -f '%FB'). A missing / zero birth time is reported as
# 'unknown' so the caller can refuse rather than guess a wrong 'latest'.
_snapshot_birthtime() {
  local d="$1" b
  [[ -d "$d" ]] || { printf 'unknown'; return 1; }
  b="$(stat -f '%FB' "$d" 2>/dev/null || true)"
  if [[ -z "$b" || "$b" == "0" || "$b" == "0."* ]]; then
    printf 'unknown'
    return 1
  fi
  printf '%s' "$b"
  return 0
}

# Snapshot dirs ordered oldest -> newest by birth time (not by name). Unknown
# birth-time snapshots (rare) are appended at the end, ordered by name, so the
# listing is still total; picking a 'latest' is handled separately.
_list_snapshot_dirs() {
  local d bt known="" unk=""
  [[ -d "$BACKUP_ROOT" ]] || return 0
  for d in "$BACKUP_ROOT"/"$APP_NAME"-*; do
    [[ -d "$d/app" ]] || continue
    bt="$(_snapshot_birthtime "$d")"
    if [[ "$bt" == "unknown" ]]; then
      unk="$unk$d"$'\n'
    else
      known="$known$bt"$'\t'"$d"$'\n'
    fi
  done
  if [[ -n "$known" ]]; then
    printf '%s' "$known" | sort -t$'\t' -k1,1n | cut -f2-
  fi
  if [[ -n "$unk" ]]; then
    printf '%s' "$unk" | sort
  fi
}

# The single newest snapshot by birth time. Returns non-zero (with a clear
# instruction) when it cannot be determined unambiguously: a snapshot with no
# birth time, or more than one sharing the newest birth time. It never guesses a
# possibly-older snapshot as default; the caller should require --rollback <id>.
_latest_snapshot_dir() {
  local d bt maxbt="" cnt=0 maxd=""
  # First pass: the maximum birth time over all snapshots.
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    bt="$(_snapshot_birthtime "$d")"
    if [[ "$bt" == "unknown" ]]; then
      warn "snapshot $d has no birth time; cannot choose a latest reliably. Use --rollback <id>."
      return 1
    fi
    if [[ -z "$maxbt" ]] || awk -v a="$bt" -v b="$maxbt" 'BEGIN{exit !(a>b)}'; then
      maxbt="$bt"
    fi
  done < <(_list_snapshot_dirs)
  [[ -z "$maxbt" ]] && return 1
  # Second pass: count snapshots at exactly that birth time.
  while IFS= read -r d; do
    bt="$(_snapshot_birthtime "$d")"
    if [[ "$bt" == "$maxbt" ]]; then
      cnt=$((cnt + 1)); maxd="$d"
    fi
  done < <(_list_snapshot_dirs)
  if [[ "$cnt" -gt 1 ]]; then
    warn "$cnt snapshots share the newest birth time ($maxbt); the latest is ambiguous. Use --rollback <id>."
    return 1
  fi
  [[ -n "$maxd" ]] && { printf '%s\n' "$maxd"; return 0; }
  return 1
}

_list_backups() {
  local d id h bid rev ts sign
  if ! _list_snapshot_dirs | grep -q . ; then
    log "No snapshots at $BACKUP_ROOT"
    return 0
  fi
  while IFS= read -r d; do
    id="$(basename "$d")"
    ts="$(grep -m1 '^timestamp=' "$d/manifest.txt" 2>/dev/null | cut -d= -f2-)"
    bid="$(grep -m1 '^bundle_id=' "$d/manifest.txt" 2>/dev/null | cut -d= -f2-)"
    sign="$(grep -m1 '^signing=' "$d/manifest.txt" 2>/dev/null | cut -d= -f2-)"
    h="$(grep -m1 '^sha256=' "$d/manifest.txt" 2>/dev/null | cut -d= -f2-)"
    rev="$(grep -m1 '^source_revision=' "$d/manifest.txt" 2>/dev/null | cut -d= -f2-)"
    printf '%s\n' "  $id  ${ts:-?}  bid=${bid:-?}  sign=${sign:-?}  sha=${h:0:16}  src=${rev:-?}"
  done < <(_list_snapshot_dirs)
}

_do_rollback() {
  local requested="${1:-}" target=""
  if [[ -n "$requested" ]]; then
    # Reject absolute, relative, or traversal paths in a user-supplied id.
    if [[ "$requested" == *"/"* || "$requested" == *"\\"* || "$requested" == ".." || "$requested" == "." ]]; then
      die "invalid rollback id: $requested"
    fi
    target="$BACKUP_ROOT/$requested"
    [[ -d "$target/app" ]] || die "rollback snapshot not found: $target"
  else
    # _latest_snapshot_dir warns (and returns non-zero) when the latest cannot be
    # determined (empty, an unknown birth time, or an ambiguous tie). Distinguish
    # empty from ambiguous so the operator gets the right instruction.
    if ! target="$( _latest_snapshot_dir )"; then
      if ! _list_snapshot_dirs | grep -q . ; then
        die "no snapshots at $BACKUP_ROOT to roll back to"
      fi
      die "cannot choose a latest snapshot automatically (an unknown birth time or an ambiguous tie); pass --rollback <id>."
    fi
  fi
  # Never trust a snapshot whose own path, app, or manifest is a symlink.
  [[ -L "$target" || -L "$target/app" || -L "$target/manifest.txt" ]] \
    && die "rollback snapshot contains a symlink; refusing to restore from it"
  _verify_bundle "$target/app" \
    || die "the rollback target failed verification; nothing was changed"
  # Verify the stored snapshot hash (previously write-only) so a partial or
  # corrupt snapshot is never restored.
  # A snapshot is only usable if it carries an exact 64-hex sha256 and the on-disk
  # copy still matches. A missing or malformed hash is a hard refusal (not skipped),
  # so a partial or corrupt snapshot can never be restored silently.
  local stored actual
  stored="$(grep -m1 '^sha256=' "$target/manifest.txt" 2>/dev/null | cut -d= -f2- || true)"
  actual="$(_app_hash "$target/app")"
  if [[ ! "$stored" =~ ^[0-9a-f]{64}$ || "$actual" != "$stored" ]]; then
    die "rollback snapshot is not trustworthy (manifest sha256 '${stored:-<missing>}', on-disk '$actual'); refusing to roll back"
  fi
  log "Rolling back to snapshot: $(basename "$target")"
  # _swap_publish snapshots (verified) the current app before restoring.
  _swap_publish "$target/app" "rollback snapshot" \
    || die "rollback failed; the current app was left untouched"
  log "Rolled back. The app you replaced was preserved as a new snapshot."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

app_install_main() {
  _resolve_config
  # Untrapped TERM/INT/HUP would kill the shell without running the EXIT trap,
  # leaking the lock and losing the aside copy. Trap each to exit us so the EXIT
  # trap (which restores the prior app and releases the lock) always runs.
  trap _final_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  case "$INSTALL_CMD" in
    list-backups)
      _list_backups
      exit 0
      ;;
    rollback)
      _acquire_lock
      _do_rollback "$INSTALL_ROLLBACK_ID"
      _release_lock
      exit 0
      ;;
    install) ;;
    *) die "unknown command: $INSTALL_CMD" ;;
  esac

  if [[ "$INSTALL_BUILD" == "1" ]]; then
    log "Building $APP_NAME.app…"
    "$ROOT/scripts/build-app.sh"
  else
    [[ -d "$DIST_APP" ]] \
      || die "--no-build requested but there is no bundle at $DIST_APP (run ./scripts/build-app.sh)"
    log "Using existing bundle at $DIST_APP"
  fi

  _acquire_lock
  _swap_publish "$DIST_APP" "candidate" || { _release_lock; exit 1; }

  # Exit 3 means the app was installed (a rollback was NOT done) but the login
  # item registration failed.
  local login_rc=0
  if [[ "$INSTALL_NO_LOGIN_ITEM" != "1" ]]; then
    if ! _register_login_item; then login_rc=3; fi
  fi

  if [[ "$INSTALL_LAUNCH" == "1" ]]; then
    log "Launching $APP_DEST…"
    open "$APP_DEST"
  else
    log "Installed to $APP_DEST (not launched). Open it from the menu bar when you want it."
  fi

  _release_lock
  if [[ "$login_rc" -ne 0 ]]; then
    log "Installed, but the login item could NOT be registered. The app is in place; fix the login item and re-run, or start $APP_NAME manually. (exit $login_rc)"
    exit "$login_rc"
  fi
  exit 0
}
