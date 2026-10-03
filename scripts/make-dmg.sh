#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Package Usage as a DMG for a GitHub release. Free path: ad-hoc signed, not
# notarized, because there is no paid Apple Developer ID.
#
#   ./scripts/make-dmg.sh                    # outputs in dist/release
#   OUT_DIR=/some/dir ./scripts/make-dmg.sh  # outputs elsewhere
#   ALLOW_DIRTY=1 ./scripts/make-dmg.sh      # package a dirty tree (marked)
#
# It builds with SIGN_IDENTITY=- (ad hoc), reads the version from the built
# Info.plist, makes Usage-<version>-macos-arm64.dmg (compressed UDZO: the app
# plus an /Applications link), writes SHA256SUMS and RELEASE_NOTES.md, then
# verifies the DMG by mounting it read-only. It never launches the app, never
# touches /Applications, and never pushes or publishes anything: the last line
# it prints is the draft-release command for you to run.

APP_NAME="Usage"
REPO="usage-menubar"
OWNER="tristan-mcinnis"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-$ROOT/dist/release}"
APP="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP/Contents"

fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ -n "$(git status --porcelain)" && "${ALLOW_DIRTY:-}" != "1" ]]; then
  fail "the working tree is dirty; commit first, or set ALLOW_DIRTY=1"
fi
[[ "$(uname -m)" == "arm64" ]] || fail "this script packages arm64 and needs an Apple Silicon Mac"

echo "• building ${APP_NAME}.app (ad-hoc signature)..."
SIGN_IDENTITY=- ./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "odd version '$VERSION' in Info.plist"
DMG_NAME="$APP_NAME-$VERSION-macos-arm64.dmg"
DMG="$OUT_DIR/$DMG_NAME"
VOLNAME="$APP_NAME $VERSION"

echo "• checking the app before it goes in the image..."
codesign --verify --strict --verbose=2 "$APP"
[[ -f "$CONTENTS/Resources/LICENSE" ]] || fail "LICENSE is not inside the app bundle"
[[ -f "$CONTENTS/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "THIRD_PARTY_NOTICES.md is not inside the app bundle"

mkdir -p "$OUT_DIR"
rm -f "$DMG" "$OUT_DIR/SHA256SUMS" "$OUT_DIR/RELEASE_NOTES.md" "$OUT_DIR/verify.log" "$OUT_DIR/draft-release-command.txt"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/usage-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true; rmdir "$MOUNT" 2>/dev/null || true; fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "• staging the image contents..."
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "• creating ${DMG_NAME}..."
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO \
  -imagekey zlib-level=9 "$DMG" >/dev/null
[[ -f "$DMG" ]] || fail "hdiutil made no image"

echo "• writing SHA256SUMS..."
( cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS )
SHA="$(cut -d' ' -f1 "$OUT_DIR/SHA256SUMS")"

COMMIT="$(git rev-parse --short HEAD)"
if git describe --tags --abbrev=0 >/dev/null 2>&1; then
  PREV="$(git describe --tags --abbrev=0)"
  NEW_LINES="$(git log --no-merges --format='- %s' "$PREV"..HEAD)"
else
  NEW_LINES="- First public release."
fi

echo "• writing RELEASE_NOTES.md..."
cat > "$OUT_DIR/RELEASE_NOTES.md" <<EOF
# $APP_NAME $VERSION

$APP_NAME is a Mac menu-bar app that shows how much of each AI plan you have used, all on one percent-used scale. It reads Claude Code, Codex and Antigravity subscription windows and DeepSeek, Moonshot and Soniox API key balances. It is free and open source (MIT). It has no account and no telemetry.

## What is new

$NEW_LINES

## Requirements

- macOS 14 or later.
- Apple Silicon (arm64). There is no Intel build.
- Whichever of the six sources you use, signed in through its own tool.

## First open

$APP_NAME is not notarized. It is a free project, and I do not pay for an Apple Developer ID, so macOS blocks the first open. Each release is signed ad hoc. Because of that, macOS may ask again for permissions such as Accessibility or Microphone after an update.

1. Open the \`.dmg\` and drag $APP_NAME to Applications.
2. Open $APP_NAME once. macOS will block it. This is expected.
3. Go to System Settings > Privacy & Security, scroll down, and click Open Anyway.

Or do it in Terminal:

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"
\`\`\`

On first launch macOS asks whether $APP_NAME may read the "Claude Code-credentials" keychain item. Choose Always Allow, or the Claude row stays at "Sign in".

## Checksum

\`\`\`
$SHA  $DMG_NAME
\`\`\`

Check it with \`shasum -a 256 -c SHA256SUMS\` in the folder that holds both files.

Built from commit \`$COMMIT\`.
EOF

echo "• verifying the image (read-only mount, app never launched)..."
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/usage-mnt.XXXXXX")"
{
  echo "image: $DMG"
  echo "sha256: $SHA"
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
  MAPP="$MOUNT/$APP_NAME.app"
  [[ -d "$MAPP" ]] || fail "no $APP_NAME.app in the image"
  [[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]] || fail "no /Applications link in the image"
  echo "-- codesign --verify --strict --verbose=2"
  codesign --verify --strict --verbose=2 "$MAPP" 2>&1
  nested_count=0
  while IFS= read -r nested; do
    nested_count=$((nested_count + 1))
    codesign --verify --strict --verbose=2 "$nested" 2>&1
  done < <(find "$MAPP/Contents" -mindepth 2 \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.dylib' \) -prune -print 2>/dev/null)
  echo "nested bundles checked: $nested_count"
  EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$MAPP/Contents/Info.plist")"
  ARCHS="$(lipo -archs "$MAPP/Contents/MacOS/$EXEC")"
  echo "lipo -archs: $ARCHS"
  [[ "$ARCHS" == "arm64" ]] || fail "expected arm64, got '$ARCHS'"
  PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MAPP/Contents/Info.plist")"
  echo "Info.plist version: $PLIST_VERSION"
  [[ "$DMG_NAME" == "$APP_NAME-$PLIST_VERSION-macos-arm64.dmg" ]] || fail "file name does not match the Info.plist version"
  [[ -f "$MAPP/Contents/Resources/LICENSE" ]] || fail "LICENSE missing in the mounted app"
  [[ -f "$MAPP/Contents/Resources/THIRD_PARTY_NOTICES.md" ]] || fail "THIRD_PARTY_NOTICES.md missing in the mounted app"
  echo "notices inside the app: LICENSE, THIRD_PARTY_NOTICES.md"
  echo "-- codesign -dv (identity)"
  codesign -dv "$MAPP" 2>&1 | grep -E 'Identifier|Signature|TeamIdentifier' || true
  echo "-- spctl --assess (a rejection is expected: not notarized)"
  spctl --assess --type execute --verbose=2 "$MAPP" 2>&1 || echo "spctl exit $? (expected for an ad-hoc, un-notarized app)"
} 2>&1 | tee "$OUT_DIR/verify.log"
hdiutil detach "$MOUNT" -quiet >/dev/null
rmdir "$MOUNT" 2>/dev/null || true
MOUNT=""

CMD="gh release create v$VERSION --repo $OWNER/$REPO --draft --title \"$APP_NAME $VERSION\" --notes-file \"$OUT_DIR/RELEASE_NOTES.md\" \"$DMG\" \"$OUT_DIR/SHA256SUMS\""
echo "$CMD" > "$OUT_DIR/draft-release-command.txt"

echo
echo "built:   $DMG"
echo "sha256:  $SHA"
echo "to draft the GitHub release (you run this, after pushing the commit):"
echo "  $CMD"
