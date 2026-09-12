#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Install Usage.app and register it as a login item.
#
#   ./scripts/install.sh                     build, install, do NOT launch
#   ./scripts/install.sh --no-launch         the same, said out loud
#   ./scripts/install.sh --launch            install and then open it
#   ./scripts/install.sh --no-build          install whatever is already in dist/
#   ./scripts/install.sh --rollback          restore the most recent backup snapshot
#   ./scripts/install.sh --rollback <id>     restore a specific backup snapshot
#   ./scripts/install.sh --list-backups      list saved snapshots
#   ./scripts/install.sh --no-login-item     skip login-item (re)registration
#   ./scripts/install.sh --allow-signing-change   replace a properly-signed app (see below)
#   ./scripts/install.sh --dest <path>       install to <path> instead of /Applications
#   ./scripts/install.sh --backup-root <p>   keep snapshots under <p> instead of the default
#   ./scripts/install.sh --dist <path>       use <path> as the bundle instead of dist/Usage.app
#
# Not launching is the default on purpose: Usage puts an item in the menu bar
# and a launch steals focus. Nothing here opens a window, reveals a folder, or
# brings an app forward unless --launch is given, and install never quits or
# relaunches a running instance on its own.
#
# Every replacement is staged and verified (codesign, plist id, executable,
# icon, LSUIElement) before the installed app is touched. The previous app is
# renamed aside, never deleted first, and kept as an immutable snapshot with its
# hash, codesign provenance and source revision outside Git. If a publish or
# post-install verification fails, the previous app is restored. A snapshot is
# kept for every install so the last good build can be restored with --rollback.
#
# A properly-signed installed app is never silently replaced with a different
# signing identity (ad-hoc, another team, or a different embedded identifier).
# That install is refused and the destination is left untouched unless
# --allow-signing-change is passed on purpose.
#
# Exit codes: 0 installed, 1 failed (nothing changed, or the prior app was
# restored), 3 the app was installed but the login item could NOT be registered
# (no rollback was done; fix the login item and re-run). A held install lock is
# refused rather than stolen; clear a stale lock and retry.
#
# The shared engine lives in scripts/app-install-lib.sh; the safety rules that
# govern replacement are documented there.

APP_NAME="Usage"
EXEC_NAME="usage-bar"
BUNDLE_ID="com.tristan.usage-menubar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

INSTALL_BUILD=1
INSTALL_LAUNCH=0
INSTALL_NO_LOGIN_ITEM=0
INSTALL_ALLOW_SIGNING_CHANGE=0
INSTALL_CMD="install"
INSTALL_ROLLBACK_ID=""
INSTALL_DEST=""
INSTALL_BACKUP_ROOT=""
INSTALL_DIST_APP=""

usage() { sed -n '5,43p' "$0"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --launch)        INSTALL_LAUNCH=1; shift ;;
    --no-launch)     INSTALL_LAUNCH=0; shift ;;
    --no-build)      INSTALL_BUILD=0; shift ;;
    --no-login-item) INSTALL_NO_LOGIN_ITEM=1; shift ;;
    --allow-signing-change) INSTALL_ALLOW_SIGNING_CHANGE=1; shift ;;
    --rollback)
      INSTALL_CMD="rollback"; INSTALL_BUILD=0
      if [[ -n "${2:-}" && "${2}" != -* ]]; then INSTALL_ROLLBACK_ID="$2"; shift; fi
      shift
      ;;
    --list-backups)  INSTALL_CMD="list-backups"; shift ;;
    --dest)          INSTALL_DEST="$2"; shift 2 ;;
    --backup-root)   INSTALL_BACKUP_ROOT="$2"; shift 2 ;;
    --dist)          INSTALL_DIST_APP="$2"; shift 2 ;;
    --help|-h)       usage; exit 0 ;;
    -*)              echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)               echo "unexpected argument: $1" >&2; usage; exit 2 ;;
  esac
done

# scripts/build-app.sh compiles the WORKING TREE, not HEAD, so installing from
# a dirty checkout produces a binary that traces to no commit at all (bitten
# 2026-09-12 in a sibling house repo: a build installed mid-edit ran for an hour
# answering in a reply format that existed only in uncommitted edits, which is
# the only reason the mismatch was ever noticed). Refuse by default; override
# deliberately with USAGE_ALLOW_DIRTY=1, and build-app.sh then stamps the
# commit as <sha>-dirty. Only the build-from-tree path is guarded: --no-build installs a
# bundle this run did not build, which already carries the stamp of the tree it
# was really built from, and --rollback / --list-backups compile nothing.
if [[ "$INSTALL_CMD" == "install" && "$INSTALL_BUILD" == "1" ]]; then
  if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    if [[ "${USAGE_ALLOW_DIRTY:-0}" == "1" ]]; then
      echo "⚠ dirty tree: this build traces to no commit; stamping it -dirty" >&2
    else
      echo "refusing to install from a dirty working tree." >&2
      git -C "$ROOT" status --short >&2
      echo "commit or stash first, or re-run with USAGE_ALLOW_DIRTY=1 to override." >&2
      exit 1
    fi
  fi
fi

export APP_NAME EXEC_NAME BUNDLE_ID ROOT
export INSTALL_BUILD INSTALL_LAUNCH INSTALL_NO_LOGIN_ITEM INSTALL_ALLOW_SIGNING_CHANGE INSTALL_CMD INSTALL_ROLLBACK_ID
export INSTALL_DEST INSTALL_BACKUP_ROOT INSTALL_DIST_APP

# shellcheck source=scripts/app-install-lib.sh
source "$ROOT/scripts/app-install-lib.sh"

app_install_main
