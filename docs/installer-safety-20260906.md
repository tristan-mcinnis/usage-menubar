# Bundle installer verification, 2026-09-06

Memory and Usage carry byte-identical, self-contained installer helpers. Neither
requires the design-system checkout at install time.

Before replacement, the candidate and retained snapshot are verified. A signed
existing app cannot silently change signing identity. Publish failures and
INT/TERM/HUP restore the prior bundle; failed restoration retains its last-good
copy and releases the lock. An unverifiable prior app blocks replacement rather
than bypassing backup.

Rollback requires a valid recorded checksum, checks it against the snapshot,
and rejects symlinked snapshot roots/apps/manifests and path traversal. Default
rollback orders by snapshot birth time, not PID-bearing names or mutable mtime;
unknown or tied newest birth times require an explicit snapshot ID.

Snapshots are never pruned or modified by the installer. “Immutable” describes
that retention contract, not filesystem immutable flags. Previously unknown
source revisions remain unknown. Stale locks are refused, never stolen.

Exit 3 means the app was installed but login-item registration failed. It is
not reported as a rollback. Normal success is 0 and install failure is nonzero.

## Independent execution

- **87 assertions passed in each repo**, zero failed.
- Genuine Apple-Development-signed bundles installed and rolled back in temporary
  destinations, with real codesign verification. Memory used distinct old/new
  binaries; Usage exercised copies of its current signed build.
- Live `/Applications` bundles were unchanged. The test used `--no-build` and
  `--no-login-item`, with no launch flag. No live app or login item was changed.
- The suite covers signing downgrade, missing/mismatched hashes, symlink and
  traversal refusal, pre-publish backup failure, signal recovery, restore faults,
  lock cleanup and creation-order selection.

The shell parser was checked against real codesign stderr. Real signatures print
`Signature size=...`, unlike ad-hoc signatures; fixtures now capture this
actual format rather than a misleading invented signature line.
