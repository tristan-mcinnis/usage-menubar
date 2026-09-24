#!/usr/bin/env bash
# shellcheck shell=bash
set -uo pipefail

# Adoption check: is Usage good enough to quit Baby Menu with no loss?
#
#   ./scripts/acceptance.sh              run T1-T6, print numbers, exit 0 only if all pass
#   ./scripts/acceptance.sh --skip-build skip T1 (build and tests), run the rest
#
# T1  `swift build` and `swift test` pass.
# T2  /Applications/Usage.app carries UsageBuiltFromCommit == `git rev-parse HEAD`.
# T3  the Usage process is running, and has been up at least 60 s (if it is
#     not running, it is launched in the background and watched for 60 s).
# T4  every source that is set up on this Mac has a last-good reading in
#     readings.json younger than 15 minutes. "Set up" comes from the installed
#     app's own `--doctor` (a NOT SET UP row is excluded, and named).
# T5  at least two sources match an independent ground truth within a stated
#     tolerance: the provider's own endpoint, read with the credential its own
#     tool keeps (the same place Usage reads it), or Baby Menu's stored reading.
# T6  docs/baby-menu-parity-20260925.md exists, names every Baby Menu widget
#     cached on this Mac, and marks every row covered / not needed (with a
#     reason) / gap.
#
# Never prints a key or a token. Launching Usage (a menu-bar app, `open -g -j`)
# is the only thing that touches the UI, and only when it is not running.
# Baby Menu's database is copied to a temp directory and read there, never
# opened in place.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${USAGE_APP:-/Applications/Usage.app}"
STATE="$HOME/Library/Application Support/Usage"
SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

declare -a SUMMARY=()
FAILED=0
record() { # name status detail
  SUMMARY+=("$1  $2  $3")
  [[ "$2" == "PASS" ]] || FAILED=1
}

echo "== T1 build and tests"
if [[ "$SKIP_BUILD" == "1" ]]; then
  record T1 SKIP "--skip-build"
else
  LOG="$(mktemp -t usage-acceptance)"
  if (cd "$ROOT" && swift build >"$LOG" 2>&1 && swift test >>"$LOG" 2>&1); then
    COUNT="$(grep -Eo 'Executed [0-9]+ tests, with [0-9]+ failures' "$LOG" | tail -1)"
    echo "  $COUNT"
    record T1 PASS "$COUNT"
  else
    tail -25 "$LOG"
    record T1 FAIL "swift build or swift test failed (log: $LOG)"
  fi
fi

echo "== T2 installed build is HEAD"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
STAMP="$(/usr/libexec/PlistBuddy -c 'Print :UsageBuiltFromCommit' "$APP/Contents/Info.plist" 2>/dev/null || echo missing)"
DIRTY="$(git -C "$ROOT" status --porcelain | head -1)"
echo "  HEAD   $HEAD_SHA"
echo "  stamp  $STAMP"
[[ -n "$DIRTY" ]] && echo "  note   working tree is dirty; HEAD is what counts"
if [[ "$STAMP" == "$HEAD_SHA" ]] && codesign --verify --deep --strict "$APP" 2>/dev/null; then
  record T2 PASS "stamp == HEAD ($HEAD_SHA), signature valid"
else
  record T2 FAIL "stamp $STAMP != HEAD $HEAD_SHA (or signature invalid)"
fi

echo "== T3 process alive for 60 s"
EXE="$APP/Contents/MacOS/usage-bar"
find_pid() { pgrep -f "^$EXE\$" | head -1; }
PID="$(find_pid)"
if [[ -z "$PID" ]]; then
  echo "  not running; launching in the background"
  open -g -j "$APP"
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; PID="$(find_pid)"; [[ -n "$PID" ]] && break; done
fi
if [[ -z "$PID" ]]; then
  record T3 FAIL "no usage-bar process after launch"
else
  ETIME_S="$(ps -o etimes= -p "$PID" 2>/dev/null | tr -d ' ')"
  if [[ -z "$ETIME_S" ]]; then
    # macOS ps has no etimes; derive seconds from etime ([[dd-]hh:]mm:ss).
    ETIME="$(ps -o etime= -p "$PID" | tr -d ' ')"
    ETIME_S="$(python3 -c "
t='$ETIME'; d=0
if '-' in t: d,t=t.split('-'); d=int(d)
p=[int(x) for x in t.split(':')]
while len(p)<3: p.insert(0,0)
print(d*86400+p[0]*3600+p[1]*60+p[2])")"
  fi
  if (( ETIME_S < 60 )); then
    WAIT=$((60 - ETIME_S + 2))
    echo "  pid $PID up ${ETIME_S}s; watching ${WAIT}s more"
    sleep "$WAIT"
  fi
  if kill -0 "$PID" 2>/dev/null; then
    ETIME="$(ps -o etime= -p "$PID" | tr -d ' ')"
    echo "  pid $PID running, up $ETIME"
    LAST_LAUNCH="$(grep ' launch ' "$STATE/events.log" 2>/dev/null | tail -1)"
    [[ -n "$LAST_LAUNCH" ]] && echo "  events.log: $LAST_LAUNCH"
    record T3 PASS "pid $PID up $ETIME"
  else
    record T3 FAIL "pid $PID exited within 60 s of launch"
  fi
fi

echo "== T4-T6 (freshness, ground truth, parity)"
DOCTOR_OUT="$("$EXE" --doctor 2>/dev/null)"
PY_OUT="$(DOCTOR_OUT="$DOCTOR_OUT" STATE="$STATE" ROOT="$ROOT" python3 - <<'PY'
import datetime, json, os, re, shutil, sqlite3, subprocess, tempfile, urllib.request

now = datetime.datetime.now(datetime.timezone.utc)
home = os.path.expanduser("~")
state = os.environ["STATE"]
root = os.environ["ROOT"]
results = {}

def iso(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))

titles = {"Claude Code": "claude", "Codex": "codex", "Antigravity": "antigravity",
          "DeepSeek": "deepseek", "Moonshot": "moonshot", "Soniox": "soniox"}
not_set_up = {}
for line in os.environ["DOCTOR_OUT"].splitlines():
    m = re.match(r"^  (\S.*?)\s{2,}NOT SET UP: (.*)$", line)
    if m and m.group(1) in titles:
        not_set_up[titles[m.group(1)]] = m.group(2)

# ---------- T4
try:
    readings = {r["provider"]: r for r in json.load(open(os.path.join(state, "readings.json")))}
except Exception as error:
    readings = {}
    print(f"  T4 cannot read readings.json: {error}")

def value_of(reading):
    parts = []
    for m in reading.get("meters", []):
        if m.get("amount") is not None:
            parts.append(f'{m["label"]} {m["amount"]:.2f} {m.get("currency","")}')
        elif m.get("percentUsed") is not None:
            parts.append(f'{m["label"]} {m["percentUsed"]:.0f}%')
    return "; ".join(parts) or "(no meters)"

t4_ok = True
for provider in ["claude", "codex", "antigravity", "deepseek", "moonshot", "soniox"]:
    if provider in not_set_up:
        print(f"  {provider:<12} not set up ({not_set_up[provider]}), excluded")
        continue
    reading = readings.get(provider)
    if not reading or not reading.get("readAt"):
        print(f"  {provider:<12} NO READING")
        t4_ok = False
        continue
    age = (now - iso(reading["readAt"])).total_seconds()
    flag = "ok" if age < 900 else "TOO OLD"
    if age >= 900:
        t4_ok = False
    print(f"  {provider:<12} {value_of(reading):<60} age {age/60:5.1f} min  {flag}")
results["T4"] = t4_ok

# ---------- T5
def get_json(url, headers, timeout=15):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)

def first_key(files, names):
    for path in files:
        try:
            text = open(os.path.expanduser(path)).read().strip().splitlines()
            if text and text[0].strip():
                return text[0].strip()
        except OSError:
            pass
    try:
        for line in open(os.path.join(home, ".config/secrets.env")):
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            for name in names:
                if line.startswith(name + "="):
                    value = line.split("=", 1)[1].strip().strip('"').strip("'")
                    if value:
                        return value
    except OSError:
        pass
    return None

def meter(provider, meter_id=None, label=None):
    for m in readings.get(provider, {}).get("meters", []):
        if (meter_id and m["id"] == meter_id) or (label and m["label"] == label):
            return m
    return None

def app_age(provider):
    r = readings.get(provider)
    return (now - iso(r["readAt"])).total_seconds() / 60 if r and r.get("readAt") else None

matched = set()
def compare(name, app_value, truth_value, tolerance, unit, truth_source):
    if app_value is None or truth_value is None:
        print(f"  {name:<24} skipped (app {app_value}, truth {truth_value})")
        return
    diff = abs(app_value - truth_value)
    ok = diff <= tolerance
    if ok:
        matched.add(name.split()[0])
    print(f"  {name:<24} app {app_value:10.2f}{unit}  truth {truth_value:10.2f}{unit}  "
          f"diff {diff:.2f} (tolerance {tolerance}{unit})  {'MATCH' if ok else 'MISMATCH'}  [{truth_source}]")

# DeepSeek: the provider's own balance endpoint, key read where Usage reads it.
try:
    key = first_key(["~/.config/deepseek/api_key", "~/.deepseek/api-key"], ["DEEPSEEK_API_KEY"])
    if key and "deepseek" not in not_set_up:
        body = get_json("https://api.deepseek.com/user/balance", {"Authorization": f"Bearer {key}", "Accept": "application/json"})
        info = next(i for i in body["balance_infos"] if i["currency"] == "CNY")
        m = meter("deepseek", meter_id="balance-cny")
        compare("DeepSeek balance CNY", m and m["amount"], float(info["total_balance"]), 1.0, " CNY", "api.deepseek.com/user/balance")
except Exception as error:
    print(f"  DeepSeek ground truth failed: {type(error).__name__}")

# Moonshot: the provider's own balance endpoint.
try:
    key = first_key(["~/.config/moonshot/api_key", "~/.config/kimi/api_key"], ["MOONSHOT_API_KEY", "KIMI_CN_API_KEY"])
    if key and "moonshot" not in not_set_up:
        body = get_json("https://api.moonshot.cn/v1/users/me/balance", {"Authorization": f"Bearer {key}"})
        m = meter("moonshot", meter_id="balance")
        compare("Moonshot balance CNY", m and m["amount"], float(body["data"]["available_balance"]), 0.01, " CNY", "api.moonshot.cn/v1/users/me/balance")
except Exception as error:
    print(f"  Moonshot ground truth failed: {type(error).__name__}")

# Claude: the OAuth usage endpoint, token read from the keychain the way Usage does.
try:
    token = None
    for args in (["-a", os.environ.get("USER", "")], []):
        out = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", *args, "-w"],
                             capture_output=True, text=True, timeout=8)
        if out.returncode == 0 and out.stdout.strip():
            blob = json.loads(out.stdout)
            oauth = blob.get("claudeAiOauth", blob)
            if oauth.get("expiresAt", 0) / 1000 > now.timestamp():
                token = oauth.get("accessToken")
                break
    if token:
        body = get_json("https://api.anthropic.com/api/oauth/usage",
                        {"Authorization": f"Bearer {token}", "anthropic-beta": "oauth-2025-04-20", "Accept": "application/json"})
        for field, meter_id, name in [("five_hour", "session", "Claude session %"), ("seven_day", "weekly", "Claude weekly %")]:
            m = meter("claude", meter_id=meter_id)
            truth = (body.get(field) or {}).get("utilization")
            compare(name, m and m["percentUsed"], truth, 3, " pt", "api.anthropic.com/api/oauth/usage")
    else:
        print("  Claude ground truth skipped: no unexpired token in the keychain")
except Exception as error:
    print(f"  Claude ground truth failed: {type(error).__name__}")

# Codex and Claude: Baby Menu's own stored reading, when Baby Menu has one
# from within 15 minutes of Usage's.
bm_dir = os.path.join(home, ".baby-menu")
if os.path.exists(os.path.join(bm_dir, "baby-menu.db")):
    temp = tempfile.mkdtemp(prefix="usage-acceptance-bm-")
    try:
        for suffix in ("", "-wal", "-shm"):
            source = os.path.join(bm_dir, "baby-menu.db" + suffix)
            if os.path.exists(source):
                shutil.copy2(source, os.path.join(temp, "baby-menu.db" + suffix))
        db = sqlite3.connect(os.path.join(temp, "baby-menu.db"))
        def cached(table):
            try:
                row = db.execute(f"select payload, at from {table} where id = 1").fetchone()
            except sqlite3.Error:
                return None, None
            return (json.loads(row[0]), row[1] / 1000) if row else (None, None)
        payload, at = cached("codex_quota_cache")
        if payload and "codex" in readings:
            gap = abs(iso(readings["codex"]["readAt"]).timestamp() - at) / 60
            if gap <= 15:
                bm = next((w["percentUsed"] for w in payload["windows"] if w.get("key") == "rate_limit:primary"), None)
                m = meter("codex", meter_id="rate-primary")
                compare("Codex weekly % (Baby Menu)", m and m["percentUsed"], bm, 3, " pt", f"Baby Menu cache, {gap:.0f} min apart")
            else:
                print(f"  Codex vs Baby Menu skipped: readings {gap:.0f} min apart")
        payload, at = cached("claude_code_quota_cache")
        if payload and "claude" in readings:
            gap = abs(iso(readings["claude"]["readAt"]).timestamp() - at) / 60
            if gap <= 15:
                bm = next((w["percentUsed"] for w in payload["windows"] if w.get("id") == "seven_day"), None)
                m = meter("claude", meter_id="weekly")
                compare("Claude weekly % (Baby Menu)", m and m["percentUsed"], bm, 3, " pt", f"Baby Menu cache, {gap:.0f} min apart")
            else:
                print(f"  Claude vs Baby Menu skipped: readings {gap:.0f} min apart")
        db.close()
    finally:
        shutil.rmtree(temp, ignore_errors=True)
else:
    print("  Baby Menu store absent; its cross-check is skipped")

print(f"  sources matched: {len(matched)} ({', '.join(sorted(matched)) or 'none'}); need at least 2")
results["T5"] = len(matched) >= 2

# ---------- T6
doc = os.path.join(root, "docs", "baby-menu-parity-20260925.md")
t6_ok = os.path.exists(doc)
if t6_ok:
    text = open(doc).read()
    rows = [l for l in text.splitlines() if l.startswith("|") and not re.match(r"^\|\s*-", l)]
    items = [l for l in rows[1:]] if rows else []
    bad = []
    counts = {"covered": 0, "not needed": 0, "gap": 0}
    for row in items:
        cells = [c.strip() for c in row.strip("|").split("|")]
        if len(cells) < 4 or cells[0].lower() in ("widget", "baby menu item"):
            continue
        status = cells[-2].lower()
        reason = cells[-1]
        kind = next((k for k in counts if status.startswith(k)), None)
        if kind is None or (kind == "not needed" and not reason):
            bad.append(cells[1] if len(cells) > 1 else row)
        else:
            counts[kind] += 1
    widgets_dir = os.path.join(home, ".baby-menu", "cache", "widgets")
    widgets = sorted(os.listdir(widgets_dir)) if os.path.isdir(widgets_dir) else []
    missing = [w for w in widgets if w not in text]
    print(f"  parity rows: {sum(counts.values())} ({counts['covered']} covered, {counts['not needed']} not needed, {counts['gap']} gap)")
    if widgets:
        print(f"  Baby Menu widgets on this Mac: {', '.join(widgets)}; missing from doc: {missing or 'none'}")
    if bad:
        print(f"  rows without a valid status or reason: {bad}")
    t6_ok = not bad and not missing and sum(counts.values()) > 0
else:
    print(f"  missing {doc}")
results["T6"] = t6_ok

print("RESULTS " + json.dumps(results))
PY
)"
echo "$PY_OUT" | grep -v '^RESULTS '
RESULTS="$(echo "$PY_OUT" | grep '^RESULTS ' | sed 's/^RESULTS //')"
[[ -n "$RESULTS" ]] || RESULTS='{}'
for t in T4 T5 T6; do
  if [[ "$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$RESULTS" "$t" 2>/dev/null)" == "True" ]]; then
    record "$t" PASS "see numbers above"
  else
    record "$t" FAIL "see numbers above"
  fi
done

echo
echo "== SUMMARY"
for line in "${SUMMARY[@]}"; do echo "  $line"; done
exit "$FAILED"
