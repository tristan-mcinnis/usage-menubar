# Baby Menu parity, 2026-09-25

Every piece of information Baby Menu shows on this Mac, and whether Usage
shows it. Read-only survey of `/Applications/Baby Menu.app`,
`~/.baby-menu/extensions/*/{components,store,server}.tsx|ts`,
`~/.baby-menu/cache/widgets/`, and a copy of `~/.baby-menu/baby-menu.db`
(cache payloads as of 2026-09-24 22:51 UTC). Baby Menu was not quit,
modified, or reconfigured.

Widgets with a cache on this Mac: `claude-code-quota`, `codex-quota`,
`deepseek-credits`, `moonshot-credits`, `antigravity-quota`, `xiaomi-mimo`.
`scripts/acceptance.sh` (T6) checks this table names each of them and that
every row is `covered`, `not needed` (with a reason), or `gap`.

Changes made for parity in this pass: set-up-only rows and a calm dot
(`notSetUp`), an expired Claude token keeps its numbers, `agy` looked for
where Baby Menu looks, the weekly reset in the footnote, and a launch log.

| Widget | Baby Menu item | Usage | Status | Reason |
| --- | --- | --- | --- | --- |
| claude-code-quota | Weekly used % (the large number) | "Weekly" meter row | covered | |
| claude-code-quota | Session (5 h) used % | "Session" meter row, and the menu-bar number | covered | |
| claude-code-quota | Model-scoped weekly (Fable today; Sonnet, Opus when reported) | "Weekly · Fable" meter row | covered | |
| claude-code-quota | Reset time of each window | Footnote names the session and weekly resets ("session resets 3h 27m · weekly 2d 3h"); added 2026-09-25 | covered | |
| claude-code-quota | "% left" beside the bar | 100 minus the shown percent | not needed | Derived from the number already shown; one axis is percent used |
| claude-code-quota | Plan badge ("max") | "Max" on the provider row | covered | |
| claude-code-quota | Source label (oauth / cli) | none | not needed | Which transport answered is not usage information |
| claude-code-quota | "metered" tag on the active scoped window | Carried on the meter (`active`), not drawn | gap | Low value: the tag marks which model week is billing; the percent is shown either way |
| claude-code-quota | Extra usage $ spent / $ limit | Not parsed | gap | Dormant: this account reports no `extra_usage` window (Baby Menu cache has none); Return opens claude.ai usage |
| claude-code-quota | CLI fallback (`claude` under `expect`) when the OAuth token is unusable | Last good numbers stay, marked "Token expired · stale N min ago", until Claude Code renews the token | gap | Usage will not launch a Claude Code session or renew the token itself (renewal rotates Claude Code's refresh token). Numbers go stale only after ~8 h with no Claude Code run |
| claude-code-quota | live / stale / off status with refreshed time | Row detail line and header age ("refreshed just now", "stale 5 min ago") | covered | |
| claude-code-quota | Error line "showing last reading" | Reason plus "stale N min ago" on the row | covered | |
| claude-code-quota | Retry button | Row context menu "Refresh Claude Code", and ⌘R | covered | |
| codex-quota | Weekly used % | "Weekly" meter row | covered | |
| codex-quota | Weekly reset time | Footnote "weekly resets in 5d 1h" | covered | |
| codex-quota | Per-feature weekly windows (gpt-reserve etc.) | "gpt-reserve · weekly" meter rows | covered | |
| codex-quota | "limit reached" badge | The window reads 100% | covered | |
| codex-quota | Plan badge ("pro") | "Pro" on the provider row | covered | |
| codex-quota | "% left", source label | none | not needed | Derived / transport detail, as for Claude |
| codex-quota | Account email | none | not needed | Usage carries no identity by rule (a reading is meters and a plan); one Codex login on this Mac |
| codex-quota | Credits balance ("no credits") | none | not needed | This account has no credits (`hasCredits: false`); nothing to show |
| codex-quota | Status, refreshed time, retry | As for Claude | covered | |
| deepseek-credits | Credits remaining (¥1121.70) | Balance on the provider row and the meter row | covered | |
| deepseek-credits | Currency badge | ¥ symbol on the amount | covered | |
| deepseek-credits | Change over the sampled span ("-¥X past 30d") | "N% of 30d peak spent" footnote and bar | covered | |
| deepseek-credits | Sparkline of the balance history | none | not needed | One axis rule: the bar is spend since the 30-day peak; Return opens the platform usage page with the full chart |
| deepseek-credits | Topped up / granted split | none | not needed | Granted is ¥0 on this account, so topped up equals the total shown |
| deepseek-credits | "not usable" badge (`is_available: false`) | Balance at ¥0.00 and 100% | not needed | DeepSeek sets it false when the balance cannot fund calls, which the empty balance already shows |
| deepseek-credits | Other currencies | One meter per currency ("Balance · USD") | covered | |
| deepseek-credits | Status, refreshed time, retry | As for Claude | covered | |
| moonshot-credits | Credits remaining (available ¥0.00) | Balance on the row and meter, 100% spent | covered | |
| moonshot-credits | Cash (-¥6.74) and vouchers (¥0) | none | gap | Low value: the arrears amount is only on the console page; the key already reads empty at 100% |
| moonshot-credits | Token quota badge (1,075,230 tokens), rate limits (rpm, tpm, concurrency), tier, host | none | not needed | Organisation capacity settings, not usage; a second axis the one-axis rule keeps out |
| moonshot-credits | Spend over the sampled span, sample count | "N% of 30d peak spent" | covered | |
| moonshot-credits | Sparkline | none | not needed | One axis rule, as for DeepSeek |
| moonshot-credits | Status, refreshed time, retry | As for Claude | covered | |
| antigravity-quota | Per group, five-hour and weekly % used with reset | Same `agy --print=/usage` call, one meter per bucket; looks in ~/.local/bin, /usr/local/bin (Baby Menu's two) and /opt/homebrew/bin | covered | |
| antigravity-quota | Error card "agy CLI not found" | Row left off the panel; `--doctor` says "NOT SET UP: agy not installed" | not needed | agy is not installed on this Mac, so both apps have nothing to read; Usage no longer turns the dot red for it |
| xiaomi-mimo | Model list and latency for api.xiaomimimo.com | none | not needed | Extension removed from ~/.baby-menu/extensions; last cache 2026-08-14; a model list is not usage |
| (host) | hello-world demo widget, recipes (copilot, cursor, grok) | none | not needed | Templates, not installed as widgets |
| (host) | Agent chat (ACP session, agent "codex") | none | not needed | Not usage information; last session 2026-08-29; Quick Launch is the house AI chat surface |
| (host) | Menu-bar item (icon only) | Gauge icon plus Claude session % | covered | |
| (host) | Open at login | Usage is a login item (install.sh registers it) | covered | |
| (Usage only) | Soniox 30-day spend | "Spent · 30d" row | covered | Baby Menu has no Soniox widget |

## Other findings

- Why Usage was not running: the login-item launch of 2026-09-13 15:22 ran
  (pid 896, polling every 5 to 10 minutes) until its last write at
  2026-09-16 09:55:22 local, and was gone before 10:25. No crash report
  survives (user DiagnosticReports keeps about a week) and the unified log
  holds no exit record, so quit versus kill versus crash cannot be proven.
  A clean relaunch on 2026-09-25 read five of six sources on its first poll
  and stayed up. The state it left behind shows why it may have been quit:
  its last-good archive held no Claude reading (the Claude row said "Sign in
  to Claude Code", which blanks the numbers and the menu-bar percent), and
  the dot was red every poll for Antigravity, whose tool is not installed.
  Both are fixed; `events.log` now records every launch and quit, so the
  next disappearance is explainable.
- Idle backoff: `PanelModel` computes a longer interval for an unopened
  panel, but the repeating timer takes its interval only when armed (launch,
  panel open, a settings change), so in practice it polls every 5 minutes.
  Left as is: freshness under 15 minutes is the adoption bar.
