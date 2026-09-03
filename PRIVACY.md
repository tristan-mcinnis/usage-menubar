# Privacy

Usage reads five sources and writes one small file. Each source is read with
a credential its own tool already keeps on this Mac: the Claude Code item in
the login keychain, `~/.codex/auth.json`, the `agy` CLI's own login, and the
DeepSeek and Moonshot key files. Usage reads those on every poll and holds
the value only for the duration of the call; it stores no credential, logs
no header, and never carries a token past the core target.

Its network calls are exactly four, one per remote source, each to that
provider's own usage or balance endpoint: `api.anthropic.com`,
`chatgpt.com`, `api.deepseek.com`, and `api.moonshot.cn` (or the base URL in
`MOONSHOT_BASE_URL`). There is no telemetry, no crash reporting, no update
check, and no other host.

The one file it writes is `~/Library/Application Support/Usage/samples.json`:
balance amounts and timestamps for the prepaid keys, kept thirty days, so a
balance can be drawn as spend since its peak. Its `UserDefaults` hold the
appearance choice, the poll interval, and which provider the status item
shows.
