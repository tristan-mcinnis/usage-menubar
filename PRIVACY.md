# Privacy

Usage reads six sources and writes four small files. Each source is read with
a credential its own tool already keeps on this Mac: the Claude Code item in
the login keychain, `~/.codex/auth.json`, the `agy` CLI's own login, and the
DeepSeek, Moonshot, and Soniox key files (`~/.config/secrets.env` and the
keychain). Usage reads those on every poll and holds the value only for the
duration of the call; it stores no credential, logs no header, and never
carries a token past the core target. The Claude Code token is cached in
memory behind a non-secret keychain-metadata fingerprint and held in memory
only, never written.

Its network calls are exactly five, one per remote source, each to that
provider's own usage or balance endpoint: `api.anthropic.com`,
`chatgpt.com`, `api.deepseek.com`, `api.moonshot.cn` (or the base URL in
`MOONSHOT_BASE_URL`), and `api.soniox.com`. Antigravity is read through the
local `agy` CLI, so it makes no network call by Usage. There is no telemetry,
no crash reporting, no update check, and no other host.

The four files it writes live at `~/Library/Application Support/Usage/` and
hold only amounts, plan names, dates, and process IDs, never a credential or a token:
`samples.json` (prepaid-balance amounts and timestamps, kept thirty days, so a
balance can be drawn as spend since its peak), `readings.json` (last-good
meters and plan per source, presented stale at launch), `retries.json`
(per-provider rate-limit retry deadlines), and `events.log` (one line per
launch and quit, with its process ID). Its `UserDefaults` hold the
appearance choice, the poll interval, and which provider the status item
shows.

The Claude Code and Codex endpoints are not documented for public use by
Anthropic or OpenAI. They may change or stop working; the README's Privacy
section says more.
