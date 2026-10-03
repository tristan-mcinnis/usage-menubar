#!/bin/sh
# Publish scrub: no user-specific paths, private notes paths, or key material
# in tracked files.
#
# Generic patterns live here. Private names (people, companies, email
# addresses, certificate IDs) belong in .scrub-private (gitignored, one ERE
# per line, matched case-insensitively) so the scanner never publishes what it
# scans for. This file is the one tracked file excluded from the scan; review
# it by hand. `swift test` runs it (PublishScrubTests). It sits in Tests/
# because macOS file systems ignore case, so a lowercase tests/ would be the
# same folder as SwiftPM's Tests/.
set -e
cd "$(dirname "$0")/.."

GENERIC='/Users/[a-z]+/|~/vault|~/memory|vault-vps|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|sk-[A-Za-z0-9]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-|hf_[A-Za-z0-9]{30,}|ghp_[A-Za-z0-9]{30,}'
PRIVATE=""
if [ -f .scrub-private ]; then
  PRIVATE=$(grep -v '^[[:space:]]*$' .scrub-private | grep -v '^#' | paste -sd'|' -)
fi

# Positive control: prove the pipeline detects a planted hit.
control=$(mktemp)
printf '/Users/nobody/leak\n' > "$control"
if ! grep -qE "$GENERIC" "$control"; then
  echo "SCRUB_SELFTEST_FAILED"; rm -f "$control"; exit 1
fi
rm -f "$control"

files() { git ls-files -z | grep -zv '^Tests/scrub\.sh$'; }

hits=$(files | xargs -0 grep -IlE "$GENERIC" 2>/dev/null || true)
if [ -n "$PRIVATE" ]; then
  private_hits=$(files | xargs -0 grep -IliE "$PRIVATE" 2>/dev/null || true)
  hits=$(printf '%s\n%s\n' "$hits" "$private_hits" | grep -v '^$' | sort -u || true)
fi
if [ -n "$hits" ]; then
  echo "PRIVATE CONTENT FOUND:"
  echo "$hits"
  exit 1
fi
echo "SCRUB_CLEAN"
