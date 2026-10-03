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

## House design system copy

`Sources/UsageBar/HouseDesign.swift` is a verbatim copy of
`design-system/generated/HouseDesign.swift` in the sibling House design
system checkout (`../design-system`), and `make check-consumers` there fails
if this copy drifts. `Sources/UsageBar/HouseUI.swift` is the Slate kit,
copied from Memory (and before that Cotype), so a component fix lands in all
the menu-bar apps. Component rules live in `../design-system/DESIGN.md`
("Menu bar panel" and "Meter row").
