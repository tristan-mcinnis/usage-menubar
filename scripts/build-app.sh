#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Build "Usage.app": a release binary wrapped in a menu-bar app bundle.
#
#   ./scripts/build-app.sh            # build dist/Usage.app
#   SIGN_IDENTITY=- ./scripts/build-app.sh   # force an ad-hoc signature
#
# The bundle is LSUIElement, so it has no Dock icon and never appears in the
# app switcher. It is signed with the first "Apple Development" identity in the
# login keychain, because TCC keys its grants to the signature and an unstable
# one makes the user re-approve after every rebuild; with no identity on the
# machine it falls back to ad-hoc.
#
# This script never launches anything. Installing is scripts/install.sh.

APP_NAME="Usage"
EXEC_NAME="usage-bar"
VERSION="1.0.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "• building the release binary…"
swift build -c release --product "$EXEC_NAME"
BIN="$(swift build -c release --product "$EXEC_NAME" --show-bin-path)/$EXEC_NAME"
[[ -x "$BIN" ]] || { echo "FAIL: no binary at $BIN" >&2; exit 1; }

echo "• assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$EXEC_NAME"
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

# The icon is rendered by the design system, never drawn by hand here.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
  echo "  no Resources/AppIcon.icns; regenerate it with:" >&2
  echo "  python3 ../design-system/icons/make-icon.py --glyph gauge --out Resources/AppIcon.icns" >&2
  exit 1
fi
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
echo "• code-signing with: $SIGN_IDENTITY"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1 || \
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature OK"

echo "built: $APP"
