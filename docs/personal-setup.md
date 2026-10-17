# Maintainer setup

Notes for the author's own Mac. Nothing here is needed to build or use Usage.

## Adoption check against Baby Menu

Usage replaced Baby Menu on the author's Mac. `scripts/acceptance.sh`
rechecks the whole install against Baby Menu parity (see
`docs/baby-menu-parity-20260925.md`):

- T1: `swift build` and `swift test` pass.
- T2: the installed build equals `git rev-parse HEAD` (`UsageBuiltFromCommit`
  in the installed `Info.plist`).
- T3: the process is alive 60 s after launch.
- T4: every set-up source has a reading under 15 minutes old.
- T5: two sources match an independent ground truth.
- T6: the parity table names every Baby Menu widget cached on the Mac.

It needs `/Applications/Usage.app`, live credentials, live provider APIs and
`~/.baby-menu`, so it is not part of the public build or test commands.

```sh
./scripts/acceptance.sh              # run T1 to T6
./scripts/acceptance.sh --skip-build # skip T1
```

## House design system package

The tokens (`HouseDesign`) and the Slate menu-bar kit (`HouseUIKit`) come from
the design-system package, pinned in `Package.swift` by GitHub URL and tag, and
`make check-consumers` in that repo fails if the pin goes missing or a copy
reappears. A component fix lands there and ships as a tag. Component rules live in `../design-system/DESIGN.md`
("Menu bar panel" and "Meter row").
