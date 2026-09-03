#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Install Usage.app into /Applications and register it as a login item.
#
#   ./scripts/install.sh              # build, install, do NOT launch
#   ./scripts/install.sh --no-launch  # the same, said out loud
#   ./scripts/install.sh --launch     # install and then open it
#   ./scripts/install.sh --no-build   # install whatever is already in dist/
#
# Not launching is the default on purpose: Usage puts an item in the menu bar
# and a launch steals focus from whatever is in front. Nothing here opens a
# window, reveals a folder, or brings an app forward unless --launch is given.

APP_NAME="Usage"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

BUILD=1
LAUNCH=0
for argument in "$@"; do
  case "$argument" in
    --launch)    LAUNCH=1 ;;
    --no-launch) LAUNCH=0 ;;
    --no-build)  BUILD=0 ;;
    *) echo "unknown flag: $argument" >&2; exit 2 ;;
  esac
done

if [[ "$BUILD" -eq 1 ]]; then
  "$ROOT/scripts/build-app.sh"
fi
[[ -d "$APP" ]] || { echo "FAIL: no bundle at $APP (run scripts/build-app.sh)" >&2; exit 1; }

echo "• installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

echo "• registering as a login item…"
osascript >/dev/null <<OSA
tell application "System Events"
    if exists login item "$APP_NAME" then delete login item "$APP_NAME"
    make login item at end with properties {name:"$APP_NAME", path:"$DEST", hidden:false}
end tell
OSA

# Self-verify: the bundle is there, it has an icon, and the plist says what it
# should. An install that "worked" but produced a Dock icon is not an install.
[[ -x "$DEST/Contents/MacOS/usage-bar" ]] || { echo "FAIL: no executable in $DEST" >&2; exit 1; }
[[ -f "$DEST/Contents/Resources/AppIcon.icns" ]] || { echo "FAIL: no icon in $DEST" >&2; exit 1; }
IDENTIFIER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$DEST/Contents/Info.plist")
UIELEMENT=$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$DEST/Contents/Info.plist")
[[ "$IDENTIFIER" == "com.tristan.usage-menubar" ]] || { echo "FAIL: bundle id is $IDENTIFIER" >&2; exit 1; }
[[ "$UIELEMENT" == "true" ]] || { echo "FAIL: LSUIElement is $UIELEMENT" >&2; exit 1; }
echo "  verified: executable, icon, bundle id, LSUIElement"

if [[ "$LAUNCH" -eq 1 ]]; then
  echo "• launching…"
  open "$DEST"
else
  echo "installed, not launched. Open it from /Applications when you want it."
fi
