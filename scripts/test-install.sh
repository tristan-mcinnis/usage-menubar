#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# install.sh unit tests. Everything runs against a temporary fixture on disk:
#   - a fake (ad-hoc signed) app bundle in a temp dist directory
#   - a destination and backup root under a temp directory
#   - a fake-bin that stubs platform commands (codesign / osascript / open) so
#     the tests can inject failures without touching /Applications, login items,
#     launchctl, `open` or any real app.
#
# It never touches a real install location and never runs build-app.sh. It does
# build real ad-hoc-signed fixture bundles so the codesign verification path is
# honest, and it routes the mutating platform calls through stubs for the
# failure-injection cases.

APP_NAME="Usage"
EXEC_NAME="usage-bar"
BUNDLE_ID="com.tristan.usage-menubar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"

TD="$(mktemp -d "${TMPDIR:-/tmp}/install-test-${APP_NAME}.XXXXXX")"
PASS=0
FAIL=0
CAPTURED=""

trap 'rm -rf "$TD"' EXIT

say()  { printf '• %s\n' "$*"; }
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }

# Build DESTDIR/$APP_NAME.app (ad-hoc signed) carrying VERSION in a marker file
# and CFBundleShortVersionString, so snapshots and the live app are distinct.
# Placed under a temp dist dir, never the real dist/.
make_bundle() {
  local dir="$1" tag="$2"
  local app="$dir/$APP_NAME.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/MacOS/$EXEC_NAME" <<EOF
#!/bin/sh
echo "$APP_NAME $tag"
EOF
  chmod +x "$app/Contents/MacOS/$EXEC_NAME"
  cat > "$app/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleExecutable</key><string>$EXEC_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$tag</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
  printf 'APPL????' > "$app/Contents/PkgInfo"
  printf 'fixture-%s' "$tag" > "$app/Contents/Resources/AppIcon.icns"
  printf '%s' "$tag" > "$app/Contents/Resources/version.txt"
  /usr/bin/codesign --force --deep --sign - "$app" >/dev/null 2>&1
}

installed_tag() {  # marker of the app currently at DEST
  cat "$1/Contents/Resources/version.txt" 2>/dev/null || true
}

# Run install.sh, capturing combined output; returns install.sh's exit code.
# stdin is /dev/null so the fake osascript never blocks on a tty.
run_capture() {
  set +e
  CAPTURED="$(bash "$INSTALL" "$@" 2>&1 </dev/null)"
  local rc=$?
  set -e
  return "$rc"
}

snapshot_count() { ls -d "$1"/"$APP_NAME"-* 2>/dev/null | wc -l | tr -d ' '; true; }

# Write the EXACT shape of a real signed app's codesign -d -vvv output: no
# 'Signature=' (a real app prints 'Signature size='), with an Authority chain and
# a real TeamIdentifier. Used so the signing-identity classifier is tested
# against the real format, not the shortened mock that the bug hid behind.
write_real_raw() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/real-codesign.raw" <<RAW
Executable=$TD/fake.app/Contents/MacOS/$EXEC_NAME
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1700
Signature size=4797
Authority=Apple Development: tristan.mcinnis@gmail.com (5SK292LG7D)
Authority=Apple Worldwide Developer Relations Certification Authority
Authority=Apple Root CA
Timestamp=2026-09-06T00:00:00Z
TeamIdentifier=QHCFP5472F
Info.plist entries=...
Identifier=$BUNDLE_ID
RAW
}

# ---------------------------------------------------------------------------
# Fixtures + stubs
# ---------------------------------------------------------------------------
make_bundle "$TD/d1" v1
make_bundle "$TD/d2" v2

mkdir -p "$TD/fakebin" "$TD/fake"
cat > "$TD/fakebin/codesign" <<'F'
#!/usr/bin/env bash
FAKEDIR="${FAKEDIR:-$TD/.none}"
# --verify: count calls and optionally inject a failure on a chosen call.
if [[ "$*" == *"--verify"* ]]; then
  n=0; [[ -f "$FAKEDIR/verify-count" ]] && n="$(cat "$FAKEDIR/verify-count")"
  n=$((n + 1)); printf '%s' "$n" > "$FAKEDIR/verify-count"
  sleep_on="$(cat "$FAKEDIR/codesign-sleep-on-call" 2>/dev/null || true)"
  sleep_secs="$(cat "$FAKEDIR/codesign-sleep-secs" 2>/dev/null || true)"
  if [[ -n "$sleep_on" && "$n" -eq "$sleep_on" && -n "$sleep_secs" ]]; then
    sleep "$sleep_secs"
  fi
  fail_at="$(cat "$FAKEDIR/codesign-verify-fail-at" 2>/dev/null || true)"
  if [[ -n "$fail_at" && "$n" -eq "$fail_at" ]]; then
    echo "FAKE codesign: injected verify failure on call $n" >&2
    exit 1
  fi
  exec /usr/bin/codesign "$@"
fi
# -d/-dv/-vvv provenance: for an exact path emit the EXACT real codesign -d
# output (Signature size=, Authority chain, TeamIdentifier) from a raw file, so
# the signing-identity classifier is exercised against the real shape, not the
# shortened `Signature=...` that a real app never prints.
if [[ "$*" == *"-d"* || "$*" == *"--verbose"* ]]; then
  realpath="$(cat "$FAKEDIR/real-identity-path" 2>/dev/null || true)"
  last="${!#}"
  if [[ -n "$realpath" && "$last" == "$realpath" && -f "$FAKEDIR/real-codesign.raw" ]]; then
    cat "$FAKEDIR/real-codesign.raw"
    exit 0
  fi
fi
exec /usr/bin/codesign "$@"
F
sed -i '' "s|\$TD|$TD|g" "$TD/fakebin/codesign"

# A fake mv that delegates to the real one but can be told to fail the
# "restore prior -> destination" move, so a restore fault is testable.
cat > "$TD/fakebin/mv" <<'F'
#!/usr/bin/env bash
FAKEDIR="${FAKEDIR:-$TD/.none}"
if [[ -f "$FAKEDIR/mv-fail-restore" ]]; then
  src_b="$(basename "$1" 2>/dev/null || true)"
  dst="$2"
  want="$(cat "$FAKEDIR/restore-dest-path" 2>/dev/null || true)"
  if [[ "$src_b" == ".${APP_NAME:-x}.prior."* && "$dst" == "$want" ]]; then
    echo "FAKE mv: injected restore failure" >&2
    exit 1
  fi
fi
exec /bin/mv "$@"
F
sed -i '' "s|\$TD|$TD|g" "$TD/fakebin/mv"

cat > "$TD/fakebin/osascript" <<'F'
#!/usr/bin/env bash
FAKEDIR="${FAKEDIR:-$TD/.none}"
mkdir -p "$FAKEDIR"; echo called > "$FAKEDIR/osascript-called"
# The delete+make block is fed via stdin (heredoc); the exists query via -e.
input="$(cat 2>/dev/null || true)"
args="$*"
if [[ "$args" == *"exists login item"* ]]; then
  if [[ -f "$FAKEDIR/osascript-login-item-exists" ]]; then echo "true"; else echo "false"; fi
  exit 0
fi
if [[ "$input" == *"make login item"* ]] && [[ -f "$FAKEDIR/osascript-fail-make" ]]; then
  echo "FAKE osascript: make login item failed" >&2
  exit 1
fi
exit 0
F
sed -i '' "s|\$TD|$TD|g" "$TD/fakebin/osascript"

cat > "$TD/fakebin/open" <<'F'
#!/usr/bin/env bash
FAKEDIR="${FAKEDIR:-$TD/.none}"
mkdir -p "$FAKEDIR"; echo called > "$FAKEDIR/open-called"
exit 0
F
sed -i '' "s|\$TD|$TD|g" "$TD/fakebin/open"
chmod +x "$TD/fakebin"/*

DEST="$TD/app/$APP_NAME.app"
BAK="$TD/backup"

say "1. fresh install: verifies candidate, publishes, leaves no snapshot (no prior)"
rm -rf "$DEST" "$BAK" "$TD/app"
if run_capture --no-build --no-login-item --dest "$DEST" --backup-root "$BAK" --dist "$TD/d1/$APP_NAME.app"; then
  pass "install.sh exit 0"
else
  fail "install.sh exit $? : $CAPTURED"
fi
[[ -d "$DEST" ]] && pass "destination bundle created" || fail "destination missing"
[[ -x "$DEST/Contents/MacOS/$EXEC_NAME" ]] && pass "executable installed" || fail "executable missing"
[[ "$(installed_tag "$DEST")" == "v1" ]] && pass "installed v1" || fail "installed tag $(installed_tag "$DEST")"
[[ "$(snapshot_count "$BAK")" == "0" ]] && pass "no snapshot on first install" || fail "unexpected snapshot"
[[ "$CAPTURED" != *"open-called"* ]] && pass "no launch/open on default" || fail "open was called on default"

say "2. reinstall: prior app snapshotted with hash + signing provenance + source_revision=unknown"
if run_capture --no-build --no-login-item --dest "$DEST" --backup-root "$BAK" --dist "$TD/d2/$APP_NAME.app"; then
  pass "reinstall exit 0"
else
  fail "reinstall exit $? : $CAPTURED"
fi
[[ "$(installed_tag "$DEST")" == "v2" ]] && pass "installed v2" || fail "installed tag $(installed_tag "$DEST")"
snap="$(basename "$(ls -d "$BAK"/"$APP_NAME"-* 2>/dev/null | tail -1)")"
if [[ -n "$snap" && "$(installed_tag "$BAK/$snap/app")" == "v1" ]]; then
  pass "snapshot holds prior (v1)"
else
  fail "snapshot did not hold prior"
fi
grep -q '^source_revision=unknown$' "$BAK/$snap/manifest.txt" && pass "manifest source_revision=unknown" || fail "manifest source_revision not unknown"
grep -q '^signing=adhoc$' "$BAK/$snap/manifest.txt" && pass "manifest signing=adhoc" || fail "manifest signing not adhoc"
grep -q '^sha256=[0-9a-f]\{64\}$' "$BAK/$snap/manifest.txt" && pass "manifest sha256 present" || fail "manifest sha256 missing"
grep -q '^bundle_id='"$BUNDLE_ID"'$' "$BAK/$snap/manifest.txt" && pass "manifest bundle id" || fail "manifest bundle id missing"
grep -q "Identifier=$BUNDLE_ID" "$BAK/$snap/manifest.txt" && pass "codesign -dv provenance recorded" || fail "codesign provenance missing"

say "3. candidate verification failure aborts before the destination is touched"
make_bundle "$TD/dcorrupt" v2
rm -f "$TD/dcorrupt/$APP_NAME.app/Contents/MacOS/$EXEC_NAME"   # corrupt candidate
before="$(snapshot_count "$BAK")"
if run_capture --no-build --no-login-item --dest "$DEST" --backup-root "$BAK" --dist "$TD/dcorrupt/$APP_NAME.app"; then
  fail "corrupt candidate unexpectedly succeeded"
else
  pass "corrupt candidate rejected (exit $?)"
fi
[[ "$(installed_tag "$DEST")" == "v2" ]] && pass "destination unchanged on candidate failure" || fail "destination changed on candidate failure"
[[ "$(snapshot_count "$BAK")" == "$before" ]] && pass "no new snapshot on candidate failure" || fail "new snapshot on candidate failure"

say "4. post-publish verify failure (stubbed codesign) restores the prior app"
DEST4="$TD/ver/app/$APP_NAME.app"
BAK4="$TD/ver/backup"
run_capture --no-build --no-login-item --dest "$DEST4" --backup-root "$BAK4" --dist "$TD/d1/$APP_NAME.app"   # existing v1
[[ "$(installed_tag "$DEST4")" == "v1" ]] && pass "precondition: v1 installed" || fail "precondition v1 not installed"
# A failing stub that authenticates the candidate, the staged copy and the
# snapshot, but breaks on the destination (fourth) verify call.
mkdir -p "$TD/fake-postverify"
rm -f "$TD/fake-postverify/verify-count"
echo 4 > "$TD/fake-postverify/codesign-verify-fail-at"
before="$(snapshot_count "$BAK4")"
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-postverify" run_capture \
    --no-build --no-login-item --dest "$DEST4" --backup-root "$BAK4" --dist "$TD/d2/$APP_NAME.app"; then
  fail "install with injected dest verify failure unexpectedly succeeded"
else
  pass "injected dest verify failure rejected (exit $?)"
fi
[[ "$(installed_tag "$DEST4")" == "v1" ]] && pass "prior app restored after post-verify failure" || fail "prior NOT restored: $(installed_tag "$DEST4")"
[[ "$(snapshot_count "$BAK4")" == "$((before + 1))" ]] && pass "verified snapshot of the prior kept" || fail "snapshot not kept: count $(snapshot_count "$BAK4")"
newest="$(basename "$(ls -d "$BAK4"/"$APP_NAME"-* 2>/dev/null | tail -1)")"
[[ -n "$newest" && "$(installed_tag "$BAK4/$newest/app")" == "v1" ]] && pass "kept snapshot holds v1" || fail "kept snapshot holds $(installed_tag "$BAK4/$newest/app")"
# No stale stage/prior siblings left on the install volume
if ls "$TD/ver/app"/.$APP_NAME.* 2>/dev/null | grep -q .; then
  fail "stage/prior siblings leaked: $(ls "$TD/ver/app"/.$APP_NAME.*)"
else
  pass "no leaked stage/prior siblings"
fi

say "5. --rollback restores the verified prior and safety-backups the current"
if run_capture --no-build --no-login-item --dest "$DEST" --backup-root "$BAK" --rollback; then
  pass "rollback exit 0"
else
  fail "rollback exit $? : $CAPTURED"
fi
[[ "$(installed_tag "$DEST")" == "v1" ]] && pass "rolled back to v1" || fail "rollback landed on $(installed_tag "$DEST")"
[[ "$(snapshot_count "$BAK")" == "2" ]] && pass "current (v2) kept as a safety snapshot (count 2)" || fail "safety snapshot count=$(snapshot_count "$BAK")"
newest="$(basename "$(ls -d "$BAK"/"$APP_NAME"-* 2>/dev/null | tail -1)")"
[[ "$(installed_tag "$BAK/$newest/app")" == "v2" ]] && pass "safety snapshot holds v2" || fail "safety snapshot holds $(installed_tag "$BAK/$newest/app")"

say "6. rollback with no snapshots fails cleanly and touches nothing"
if run_capture --no-build --no-login-item --dest "$TD/e/$APP_NAME.app" --backup-root "$TD/e2" --rollback; then
  fail "rollback with no snapshots unexpectedly succeeded"
else
  pass "rollback with no snapshots rejected (exit $?)"
fi
[[ "$CAPTURED" == *"no snapshots"* ]] && pass "reported no snapshots" || fail "did not report no snapshots"

say "7. login-item failure is reported truthfully and the app is still installed"
DEST7="$TD/app7/$APP_NAME.app"
BAK7="$TD/backup7"
mkdir -p "$TD/fake-login"
touch "$TD/fake-login/osascript-login-item-exists"   # a login item existed before
touch "$TD/fake-login/osascript-fail-make"           # the make step fails
rm -f "$TD/fake-login/osascript-called"
rc=0
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-login" run_capture \
    --no-build --dest "$DEST7" --backup-root "$BAK7" \
    --dist "$TD/d1/$APP_NAME.app"; then
  fail "install with a failing login item unexpectedly succeeded"
else
  rc=$?
fi
[[ "$rc" -eq 3 ]] && pass "login-item failure exits 3 (installed, no rollback)" || fail "login-item failure exit $rc (wanted 3)"
[[ -d "$DEST7" ]] && pass "app installed despite login-item failure" || fail "app missing after login-item failure"
[[ -f "$TD/fake-login/osascript-called" ]] && pass "osascript was consulted" || fail "osascript was never consulted"
grep -q "login item could NOT be updated" <<<"$CAPTURED" 2>/dev/null && pass "truthful login-item warning shown" || fail "no truthful login-item warning"

say "8. --no-login-item installs without consulting osascript"
DEST8="$TD/app8/$APP_NAME.app"
BAK8="$TD/backup8"
mkdir -p "$TD/fake-nologin"
rm -f "$TD/fake-nologin/osascript-called"
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-nologin" bash "$INSTALL" \
    --no-build --no-login-item --dest "$DEST8" --backup-root "$BAK8" \
    --dist "$TD/d1/$APP_NAME.app" >/dev/null 2>&1; then
  pass "no-login-item install exit 0"
else
  fail "no-login-item install failed"
fi
[[ ! -f "$TD/fake-nologin/osascript-called" ]] && pass "osascript not called with --no-login-item" || fail "osascript called despite --no-login-item"

say "9. concurrent lock: held locks are refused (never stolen), no GNU timeout"
DEST9="$TD/app9/$APP_NAME.app"
BAK9="$TD/backup9"
mkdir -p "$TD/app9" "$TD/app9/.$APP_NAME.install.lock"
echo 999999 > "$TD/app9/.$APP_NAME.install.lock/pid"   # a dead pid (stale lock)
if run_capture --no-build --no-login-item --dest "$DEST9" --backup-root "$BAK9" --dist "$TD/d1/$APP_NAME.app"; then
  fail "stale lock was not refused"
else
  pass "stale lock refused (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'stale install lock' && pass "refusal names the stale lock" || fail "refusal did not name the stale lock"
[[ -d "$TD/app9/.$APP_NAME.install.lock" ]] && pass "stale lock left for the operator (not stolen)" || fail "stale lock was stolen/removed"
# The operator clears it, then install succeeds.
rm -rf "$TD/app9/.$APP_NAME.install.lock"
if run_capture --no-build --no-login-item --dest "$DEST9" --backup-root "$BAK9" --dist "$TD/d1/$APP_NAME.app"; then
  pass "install succeeds after clearing the stale lock"
else
  fail "install failed after clearing stale lock: $CAPTURED"
fi
[[ -d "$DEST9" ]] && pass "destination installed after clearing lock" || fail "destination missing after clearing lock"

# A live lock (this shell's pid) is also refused, cheaply (no timeout binary).
DEST9b="$TD/app9b/$APP_NAME.app"
mkdir -p "$TD/app9b" "$TD/app9b/.$APP_NAME.install.lock"
echo $$ > "$TD/app9b/.$APP_NAME.install.lock/pid"   # a live pid (this shell)
if run_capture --no-build --no-login-item --dest "$DEST9b" --backup-root "$TD/backup9b" --dist "$TD/d1/$APP_NAME.app"; then
  fail "live lock did not block the install"
else
  pass "live lock refused (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'already running' && pass "refusal names the running install" || fail "refusal did not name the running install"
[[ -d "$TD/app9b/.$APP_NAME.install.lock" ]] && pass "live lock left intact (never stolen)" || fail "live lock stolen/removed"
rm -rf "$TD/app9b/.$APP_NAME.install.lock"

say "10. symlinked destination is refused (paths/symlink defensive)"
DEST10="$TD/app10/$APP_NAME.app"
mkdir -p "$TD/real" "$TD/app10"
# create the real target so the symlink is not dangling, then point DEST at it
make_bundle "$TD/real" v1
ln -s "$TD/real/$APP_NAME.app" "$DEST10"
[[ -L "$DEST10" ]] && pass "symlink fixture set up" || fail "symlink fixture not set up"
if run_capture --no-build --no-login-item --dest "$DEST10" --backup-root "$TD/backup10" --dist "$TD/d1/$APP_NAME.app"; then
  fail "install over a symlink unexpectedly succeeded"
else
  pass "symlinked destination refused (exit $?)"
fi

say "11. --list-backups and --rollback <id> restore a specific snapshot"
DEST11="$TD/app11/$APP_NAME.app"
BAK11="$TD/backup11"
run_capture --no-build --no-login-item --dest "$DEST11" --backup-root "$BAK11" --dist "$TD/d1/$APP_NAME.app"   # v1
run_capture --no-build --no-login-item --dest "$DEST11" --backup-root "$BAK11" --dist "$TD/d2/$APP_NAME.app"   # v2
if run_capture --no-build --list-backups --dest "$DEST11" --backup-root "$BAK11"; then
  pass "list-backups exit 0"
else
  fail "list-backups failed: $CAPTURED"
fi
printf '%s\n' "$CAPTURED" | grep -q 'src=unknown' && pass "list shows src=unknown" || fail "list missing src=unknown"
printf '%s\n' "$CAPTURED" | grep -q 'sign=adhoc' && pass "list shows sign=adhoc" || fail "list missing sign=adhoc"
v1id="$(basename "$(ls -d "$BAK11"/"$APP_NAME"-* 2>/dev/null | head -1)")"
if run_capture --no-build --no-login-item --rollback "$v1id" --dest "$DEST11" --backup-root "$BAK11"; then
  pass "rollback <id> exit 0"
else
  fail "rollback <id> failed: $CAPTURED"
fi
[[ "$(installed_tag "$DEST11")" == "v1" ]] && pass "specific rollback restored v1" || fail "rollback <id> landed on $(installed_tag "$DEST11")"

say "12. signing-identity mismatch on a properly-signed app is refused by default"
DEST12="$TD/app12/$APP_NAME.app"
BAK12="$TD/backup12"
# Existing app: a real ad-hoc-signed v1 (first install, so no snapshot yet).
run_capture --no-build --no-login-item --dest "$DEST12" --backup-root "$BAK12" --dist "$TD/d1/$APP_NAME.app"
[[ "$(installed_tag "$DEST12")" == "v1" ]] && pass "precondition: v1 installed" || fail "precondition v1 not installed"
# Simulate the installed app carrying a real (non-adhoc) signing identity using
# the EXACT captured real codesign -d shape.
mkdir -p "$TD/fake-real"
printf '%s' "$DEST12" > "$TD/fake-real/real-identity-path"
write_real_raw "$TD/fake-real"
before="$(snapshot_count "$BAK12")"
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-real" run_capture \
    --no-build --no-login-item --dest "$DEST12" --backup-root "$BAK12" --dist "$TD/d2/$APP_NAME.app"; then
  fail "signing-identity mismatch was not refused"
else
  pass "signing-identity mismatch refused (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'allow-signing-change' && pass "refusal mentions --allow-signing-change" || fail "refusal does not mention override"
[[ "$(installed_tag "$DEST12")" == "v1" ]] && pass "old app preserved on refusal" || fail "old app replaced on refusal"
[[ "$(snapshot_count "$BAK12")" == "$before" ]] && pass "backup history preserved on refusal" || fail "backup history changed on refusal"

say "13. --allow-signing-change deliberately overrides the refusal"
mkdir -p "$TD/fake-real2"
printf '%s' "$DEST12" > "$TD/fake-real2/real-identity-path"
write_real_raw "$TD/fake-real2"
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-real2" run_capture \
    --no-build --no-login-item --allow-signing-change --dest "$DEST12" --backup-root "$BAK12" --dist "$TD/d2/$APP_NAME.app"; then
  pass "override install exit 0"
else
  fail "override install failed: $CAPTURED"
fi
[[ "$(installed_tag "$DEST12")" == "v2" ]] && pass "override installed v2" || fail "override landed on $(installed_tag "$DEST12")"
[[ "$(snapshot_count "$BAK12")" == 1 ]] && pass "override kept v1 as a snapshot" || fail "override snapshot count=$(snapshot_count "$BAK12")"

say "14. classifier reads the EXACT real codesign -d shape (real:/adhoc/unsigned)"
mkdir -p "$TD/fake-class"
cat > "$TD/fake-class/codesign" <<'F'
#!/usr/bin/env bash
FAKEDIR="${FAKEDIR:-$TD/.none}"
if [[ -f "$FAKEDIR/unsigned" ]]; then echo "not signed" >&2; exit 1; fi
if [[ "$*" == *"--verify"* ]]; then exit 0; fi
cat "$FAKEDIR/real-codesign.raw" 2>/dev/null || true
exit 0
F
chmod +x "$TD/fake-class/codesign"
# Exact real signed-app shape (write_real_raw) and the ad-hoc / unsigned shapes.
write_real_raw "$TD/class-real"
mkdir -p "$TD/class-adhoc"
printf 'Identifier=%s\nSignature=adhoc\nTeamIdentifier=not set\n' "$BUNDLE_ID" > "$TD/class-adhoc/real-codesign.raw"
mkdir -p "$TD/class-unsigned"
touch "$TD/class-unsigned/unsigned"
# Source the lib so its _codesign_summary is exercised directly.
source "$ROOT/scripts/app-install-lib.sh"
r="$(PATH="$TD/fake-class:$PATH" FAKEDIR="$TD/class-real" _codesign_summary "$TD/path.app")"
[[ "$r" == real:* ]] && pass "real signed classified as real:*" || fail "real signed classified as '$r'"
[[ "$r" == *"$BUNDLE_ID" ]] && pass "identifier parsed from the real shape" || fail "identifier missing: '$r'"
a="$(PATH="$TD/fake-class:$PATH" FAKEDIR="$TD/class-adhoc" _codesign_summary "$TD/path.app")"
[[ "$a" == "adhoc" ]] && pass "explicit Signature=adhoc classified as adhoc" || fail "adhoc classified as '$a'"
u="$(PATH="$TD/fake-class:$PATH" FAKEDIR="$TD/class-unsigned" _codesign_summary "$TD/path.app")"
[[ "$u" == "unsigned" ]] && pass "failing codesign classified as unsigned" || fail "unsigned classified as '$u'"

say "15. rollback guards refuse untrustworthy snapshots and id traversal"
DEST15="$TD/roll/app/$APP_NAME.app"
BAK15="$TD/roll/backup"
run_capture --no-build --no-login-item --dest "$DEST15" --backup-root "$BAK15" --dist "$TD/d1/$APP_NAME.app"   # v1
run_capture --no-build --no-login-item --dest "$DEST15" --backup-root "$BAK15" --dist "$TD/d2/$APP_NAME.app"   # v2 -> snapshot v1
snap="$(basename "$(ls -d "$BAK15"/"$APP_NAME"-* 2>/dev/null | head -1)")"
[[ "$snap" == "$APP_NAME"-* ]] && pass "precondition: snapshot exists" || fail "precondition: no snapshot"
# (a) missing hash
cp -R "$BAK15/$snap" "$BAK15/g-missing"
sed -i '' '/^sha256=/d' "$BAK15/g-missing/manifest.txt"
if run_capture --no-build --no-login-item --rollback g-missing --dest "$DEST15" --backup-root "$BAK15"; then
  fail "rollback with a missing hash was not refused"
else
  pass "missing hash refused (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'not trustworthy' && pass "missing-hash refusal message" || fail "missing-hash message: $CAPTURED"
# (b) mismatched hash
cp -R "$BAK15/$snap" "$BAK15/g-mismatch"
sed -i '' 's/^sha256=.*/sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$BAK15/g-mismatch/manifest.txt"
if run_capture --no-build --no-login-item --rollback g-mismatch --dest "$DEST15" --backup-root "$BAK15"; then
  fail "rollback with a mismatched hash was not refused"
else
  pass "mismatched hash refused (exit $?)"
fi
# (c) symlinked app bundle
cp -R "$BAK15/$snap" "$BAK15/g-symapp"
rm -rf "$BAK15/g-symapp/app"
ln -s "$BAK15/$snap/app" "$BAK15/g-symapp/app"
if run_capture --no-build --no-login-item --rollback g-symapp --dest "$DEST15" --backup-root "$BAK15"; then
  fail "rollback with a symlinked app bundle was not refused"
else
  pass "symlink app refused (exit $?)"
fi
# symlinked manifest
cp -R "$BAK15/$snap" "$BAK15/g-symman"
rm -f "$BAK15/g-symman/manifest.txt"
ln -s "$BAK15/$snap/manifest.txt" "$BAK15/g-symman/manifest.txt"
if run_capture --no-build --no-login-item --rollback g-symman --dest "$DEST15" --backup-root "$BAK15"; then
  fail "rollback with a symlinked manifest was not refused"
else
  pass "symlink manifest refused (exit $?)"
fi
# (d) traversal ids
for bad in '..' '../../etc' '.'; do
  if run_capture --no-build --no-login-item --rollback "$bad" --dest "$DEST15" --backup-root "$BAK15"; then
    fail "rollback id '$bad' was not refused"
  else
    pass "traversal '$bad' refused (exit $?)"
  fi
done
[[ "$(installed_tag "$DEST15")" == "v2" ]] && pass "destination unchanged after all guards" || fail "destination changed by a guard"

say "16. an unverifiable installed app blocks replacement before publish"
DEST16="$TD/backupfail/app/$APP_NAME.app"
BAK16="$TD/backupfail/backup"
run_capture --no-build --no-login-item --dest "$DEST16" --backup-root "$BAK16" --dist "$TD/d1/$APP_NAME.app"   # v1
rm -f "$DEST16/Contents/MacOS/$EXEC_NAME"   # make the installed app unverifiable
before="$(snapshot_count "$BAK16")"
if run_capture --no-build --no-login-item --dest "$DEST16" --backup-root "$BAK16" --dist "$TD/d2/$APP_NAME.app"; then
  fail "install over an unverifiable old app unexpectedly succeeded"
else
  pass "unverifiable old app blocked (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'verified backup' && pass "blocked-before-publish message" || fail "block-before message: $CAPTURED"
printf '%s\n' "$CAPTURED" | grep -qi 'no backup-skip override' && pass "no backup-skip override documented" || fail "no override message: $CAPTURED"
[[ "$(snapshot_count "$BAK16")" == "$before" ]] && pass "no snapshot created (blocked before publish)" || fail "snapshot created"
[[ ! -x "$DEST16/Contents/MacOS/$EXEC_NAME" ]] && pass "old app left in place (not replaced)" || fail "old app was replaced"

say "17. SIGTERM during the swap restores the prior app, exits 143, and releases the lock"
DEST17="$TD/signal/app/$APP_NAME.app"
BAK17="$TD/signal/backup"
run_capture --no-build --no-login-item --dest "$DEST17" --backup-root "$BAK17" --dist "$TD/d1/$APP_NAME.app"   # v1
mkdir -p "$TD/fake-signal"
echo 4 > "$TD/fake-signal/codesign-sleep-on-call"
echo 8 > "$TD/fake-signal/codesign-sleep-secs"
rm -f "$TD/fake-signal/verify-count"
set +e
PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-signal" bash "$INSTALL" \
    --no-build --no-login-item --dest "$DEST17" --backup-root "$BAK17" --dist "$TD/d2/$APP_NAME.app" </dev/null >/dev/null 2>&1 &
pid=$!
sleep 3
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
set -e
[[ "$rc" -eq 143 ]] && pass "SIGTERM exits 143" || fail "SIGTERM exit $rc (wanted 143)"
[[ "$(installed_tag "$DEST17")" == "v1" ]] && pass "prior app restored after SIGTERM" || fail "post-SIGTERM dest $(installed_tag "$DEST17")"
[[ ! -d "$TD/signal/app/.$APP_NAME.install.lock" ]] && pass "lock cleaned up after SIGTERM" || fail "lock left behind after SIGTERM"
if ls "$TD/signal/app"/.$APP_NAME.* 2>/dev/null | grep -q .; then
  fail "siblings leaked after SIGTERM: $(ls "$TD/signal/app"/.$APP_NAME.*)"
else
  pass "no leaked siblings after SIGTERM"
fi

say "18. a failed restore preserves the last good copy (never deleted)"
DEST18="$TD/restfault/app/$APP_NAME.app"
BAK18="$TD/restfault/backup"
run_capture --no-build --no-login-item --dest "$DEST18" --backup-root "$BAK18" --dist "$TD/d1/$APP_NAME.app"   # v1
mkdir -p "$TD/fake-rest"
printf '%s' "$DEST18" > "$TD/fake-rest/restore-dest-path"
touch "$TD/fake-rest/mv-fail-restore"          # makes mv fail only the prior -> dest move
rm -f "$TD/fake-rest/verify-count"
echo 4 > "$TD/fake-rest/codesign-verify-fail-at"   # post-publish verify fails -> triggers restore
if PATH="$TD/fakebin:$PATH" FAKEDIR="$TD/fake-rest" run_capture \
    --no-build --no-login-item --dest "$DEST18" --backup-root "$BAK18" --dist "$TD/d2/$APP_NAME.app"; then
  fail "install unexpectedly succeeded"
else
  pass "post-verify failure rejected (exit $?)"
fi
printf '%s\n' "$CAPTURED" | grep -qi 'could NOT be restored\|preserved at' && pass "restore-fault reported truthfully" || fail "restore-fault message: $CAPTURED"
prior="$(find "$TD/restfault/app" -maxdepth 1 -name ".$APP_NAME.prior.*" | head -1)"
[[ -n "$prior" && "$(installed_tag "$prior")" == "v1" ]] && pass "last good copy preserved on restore fault" || fail "last good copy not preserved (found: '$prior')"
[[ ! -d "$TD/restfault/app/.$APP_NAME.install.lock" ]] && pass "lock cleaned after restore fault" || fail "lock left after restore fault"

say "19. default latest is chosen by birth time, not reverse-lexical names (PID-wrap regression)"
BAK19="$TD/bt/backup"
rm -rf "$BAK19"
# Snapshot dirs whose NAMES are the reverse of their creation order: the
# lexically-LARGER name (Memory-z) is created FIRST (oldest), the lexically-SMALLER
# (Memory-a) LAST (newest). Name-sort would pick Memory-z as "latest"; birth-time
# order must pick Memory-a, reproducing the PID-wrap '99000 < 1000' reorder.
mkdir -p "$BAK19/$APP_NAME-z/app"; sleep 0.15
mkdir -p "$BAK19/$APP_NAME-q/app"; sleep 0.15
mkdir -p "$BAK19/$APP_NAME-a/app"
got="$(BACKUP_ROOT="$BAK19" APP_NAME="$APP_NAME" ROOT="$ROOT" bash -c 'source "$ROOT/scripts/app-install-lib.sh"; _latest_snapshot_dir')"
[[ "$(basename "$got")" == "$APP_NAME-a" ]] && pass "birth-time order picks the actual newest ($APP_NAME-a)" || fail "latest picked '$(basename "$got")' (wanted $APP_NAME-a)"
lexlast="$(basename "$(for l in "$BAK19"/"$APP_NAME"-*; do echo "$l"; done | sort | tail -1)")"
[[ "$lexlast" == "$APP_NAME-z" ]] && pass "fixture: lexically-last name is the OLDEST (as intended)" || fail "fixture lexical order wrong (last=$lexlast)"

# ---------------------------------------------------------------------------
say ""
say "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
