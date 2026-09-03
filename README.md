# Usage

One menu-bar panel for every metered AI source on this Mac, each on the same
axis. A gauge in the status bar: how much of each subscription's window is
used, how much of each prepaid key is left, and when the tight one resets,
without opening a browser tab per provider.

Usage owns nothing. Every number is read from a source that already exists
here, on every poll, and no credential is ever stored by Usage. A plain API
key is looked for in its key file, then by name in `~/.config/secrets.env`,
then in the environment, then in the keychain:

| Row | Lane | What it reads |
| --- | --- | --- |
| Claude Code | Subscription | The Claude Code OAuth token in the login keychain, then `api.anthropic.com/api/oauth/usage`: session (5 h), weekly, and the model-scoped weekly windows |
| Codex | Subscription | `~/.codex/auth.json`, then `chatgpt.com/backend-api/wham/usage`: the primary and secondary rate windows and any per-feature cap |
| Antigravity | Subscription | `agy --output-format json --print=/usage`: every bucket, as percent used |
| DeepSeek | API key | `~/.config/deepseek/api_key`, then `api.deepseek.com/user/balance` |
| Moonshot | API key | `~/.config/moonshot/api_key`, then `api.moonshot.cn/v1/users/me/balance` |
| Soniox | API key | `SONIOX_API_KEY` in `~/.config/secrets.env`, then `api.soniox.com/v1/usage/summary`: spend over the last 30 days (Soniox has no balance endpoint) |

Return on a provider row opens that provider's own usage page. ⌘R refreshes.

## One axis

Every meter is *percent used*. A rate window reports it directly. A balance
reports it as spend since the highest balance seen in the last thirty days,
so a top-up resets the bar the way a weekly reset does. That is the whole
"apples to apples": a Claude session at 42 %, a Codex week at 63 %, and a
DeepSeek key 24 % down from its peak sit in one column of bars.

The only thing Usage writes is those balance samples, amounts only, at
`~/Library/Application Support/Usage/samples.json`.

## The panel

300 px of glass in place of an NSMenu, following the "Menu bar panel" and
"Meter row" components in `../design-system/DESIGN.md`. A 26 px icon tile,
the app name, a status line with a 6 px dot ("5 sources · refreshed 2 min
ago"). Then two groups, SUBSCRIPTIONS and API KEYS. Each provider is a
two-line row (name over lane, plan or balance on the right) followed by its
meter rows: window name, a 4 px ink bar, the number, and a footnote naming
the soonest reset. A provider with more than four windows shows the fullest
four and says how many it folded.

Arrows move the selection, Return opens the provider's usage page, Escape
closes. The panel closes when it loses focus.

The status dot is the only colour: green when every source read, red when
any did not, dim before the first read. A source that could not be read says
why in its own row, in words, in red: "Sign in to Codex", "timeout", "HTTP
404". A number Usage did not get back is never drawn.

## Status item

The gauge from the app icon, as a template image, with the chosen
subscription's session percent beside it (Settings › Menu bar; Claude by
default, or none). The gauge is painted `danger` only when a subscription
window is at its cap.

## Build and install

```
swift build && swift test          # the parsers, against fixture payloads
./scripts/build-app.sh             # dist/Usage.app, signed
./scripts/install.sh --no-launch   # into /Applications, login item, no launch
```

`install.sh` does not launch the app: it puts an item in the menu bar and a
launch steals focus. Pass `--launch` when you want it opened.

Two diagnostics, neither of which puts a window on screen:

```
usage-bar --doctor                 # every source, read once and printed
usage-bar --render-proof <dir>     # every Slate surface, as PNGs
```

On first launch macOS asks whether Usage may read the "Claude Code-credentials"
keychain item. Choose Always Allow, or the Claude row stays at "Sign in".

## Requirements

- macOS 14 or later, Apple Silicon.
- Whichever of the five sources you use, signed in through its own tool. A
  source that is not set up shows as "No DeepSeek key", "agy not installed",
  and so on; the others still read.

## Design

The look is the house system: `../design-system/DESIGN.md` is the rule,
`Sources/UsageBar/HouseDesign.swift` is a verbatim copy of the generated
token file, and `make check-consumers` in that repository fails if this copy
drifts. `Sources/UsageBar/HouseUI.swift` is the Slate component kit, copied
from Memory (and before that Cotype) so the menu bars are one look.

## License

Private. One Mac, one user.
