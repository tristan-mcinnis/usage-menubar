# usage-menubar: agent notes

`AGENTS.md` is a symlink to this file. One way of doing each thing; when a
change would create a second way, change the first one instead.

Usage is the menu-bar face of every metered AI source on this Mac. It owns
no account, no credential, and no store beyond a file of balance samples.
Every number it shows came out of a provider's own endpoint or CLI, read with
a credential the provider's own tool already keeps. If a feature would need
Usage to hold a secret of its own, the feature is wrong.

Two targets. `UsageBarCore` is pure: the meter model, one parser per source,
the credential readers, the one HTTP call, and the sample store, with no
AppKit, no window, and no timer. `UsageBar` is the app: the view layer, the
polling, and the status item. Tests live only on the core, against payloads
in `Tests/UsageBarCoreTests/Fixtures/`.

## What must never break

- **One axis.** Every meter is percent used. A rate window reports it; a
  balance reports spend since its 30-day peak (`SampleStore`). Do not add a
  second axis (tokens, requests, dollars) to a meter row; that is what the
  provider's own page is for, and Return opens it.
- **No secret leaves the core.** A `ProviderReading` carries meters and a
  plan name, never a token. `--doctor` prints "present" or "absent", never a
  value. Nothing logs a header.
- **No shell interpolation.** `Subprocess.run` is the only place a `Process`
  is built; it takes an executable path and an argument array.
- **Nothing blocks the main thread.** Every read runs on the model's work
  queue and comes back through `DispatchQueue.main`. Each network call and
  the `agy` launch carry their own timeout.
- **No window without being asked.** `install.sh` does not launch,
  `--render-proof` and `--doctor` set `.prohibited` and exit, and the only
  code that takes the foreground is behind a row the user picked.
- **Say unknown when it is unknown.** A null window is dropped, not drawn as
  0. A source that failed says why in its row. A balance with no spend yet
  draws an empty track. Never fabricate a reassuring number.
- **Never re-spell a source's words.** Window labels come from the source's
  own field names and display names ("Weekly · Opus", "Gemini Models ·
  weekly"); Usage decides which fit in 300 px, not what they say.

## Conventions

- House design through the generated token file. `Sources/UsageBar/
  HouseDesign.swift` is a verbatim copy of `design-system/generated/
  HouseDesign.swift`; never hand-edit it. `HouseUI.swift` is the Slate kit
  copied from Memory: a fix to a component lands in Memory and Cotype too.
- The Meter row is a registered component (`design-system/components.json`,
  key `meter-row`). Change its spec there first, then here.
- Adding a source is one case on `ProviderID` (title, lane, glyph, usage
  URL), one parser in `Parsers.swift` with a fixture and a test, and one
  function in `ProviderReader`. The panel, the doctor, and the settings
  sources card pick it up from `ProviderID.allCases`.
- The endpoint shapes were confirmed against Baby Menu's provider code
  (`~/.baby-menu/extensions/*/server.ts`, 2026-09), which read the live
  endpoints; the fixtures are written to those shapes, not captured from an
  account, so they carry no identity.
- The panel width, the four-row meter budget, the poll floor, and the
  60-second open-refresh age are constants on `PanelModel`, not numbers in a
  view.
- Verify with the render proof and `--doctor`, never by launching the app. A
  claim about how a surface looks is backed by a PNG somebody looked at.

## Related repositories

- `../design-system`: the rule (`DESIGN.md`), the token generator, and the
  component registry. Its `CONSUMERS` list names this repo's copy.
- `../memory-menubar`: the panel plumbing, the settings shell, the render
  proof and the doctor were ported from here.
- `../cotype`: the first Slate menu-bar app and the origin of the kit.

## Voice

One declarative sentence first. Mechanism, not benefit-speak. No marketing
adjectives, no em dashes. State limits early.
