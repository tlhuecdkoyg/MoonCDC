# Changelog

## 0.3.1 — 2026-11-07

- Preserve SQLite parameter comparison semantics while retaining UTF-8/BOM-safe
  binding. The internal CAST now has no expression affinity, preventing false
  comparisons and unintended updates for numeric-looking TEXT parameters.
- Inspect actual SQLite table kinds instead of searching CREATE TABLE text, so
  ordinary identifiers and defaults containing `VIRTUAL TABLE` remain supported.
- Verify failed capture upgrades leave definitions, journals and consumer state
  intact on insufficient budgets, invalid events and unknown trigger definitions.
- Clarify that connection-local TEMP business triggers are unsupported and cannot
  be completely inspected by persistent main-schema capture triggers.
- Capture trigger definitions are unchanged from 0.3.0; no additional upgrade is
  required for an intact 0.3.0 source.

## 0.3.0 — 2026-11-07

- Reject ordinary sync against a filtered target before any acknowledgement repair.
- Preserve valid TEXT bytes, including leading BOM, using strict raw UTF-8 capture
  decoding and UTF-8 parameter binding. Reject invalid TEXT rather than silently
  transcoding it. Capture/projection databases now explicitly require UTF-8.
- Abort source writes containing non-finite REALs or additional same-table business
  triggers; refuse installing capture on tables with such triggers.
- Add atomic, audited `upgrade-capture` for intact 0.2.0 trigger definitions.
- Normalize database REAL zeros to positive zero in both snapshots and events;
  explicitly limit database bit fidelity to nonzero finite REALs. Core wire retains -0.
- Bound direct predicate encoding, including cyclic inputs, and preserve actual
  diagnostic messages in CLI errors and operation reports.
- Add concurrent writer/sync/pruning tests and protection/Unicode/upgrade regressions.

## 0.2.0 — 2026-11-06

- Fix the acceptance-reported REAL fidelity failure: SQLite decimal formatting
  changed values such as `1e300` and could make ordinary post-snapshot updates fail
  strict before-image comparison.
- Encode REAL as a signed integer significand and binary exponent. Core wire
  encoding/decoding constructs IEEE-754 bits directly; persistent SQLite triggers
  use eleven stages of exact power-of-two scaling, with factors derived by squaring.
  Neither new path uses floating decimal formatting/parsing.
- Retain read compatibility for legacy two-element decimal REAL values. Existing
  capture triggers fail the new verifier and require a fresh capture generation,
  snapshot, consumer and target. Already lost precision cannot be recovered by
  decoding an old journal; see [the upgrade procedure](docs/OPERATIONS.md#upgrading-from-010-to-020).
- Add bitwise REAL regression coverage for `±1e300`, finite exponent boundaries,
  subnormals, signed zero in the core model, malformed pairs, JSON/JSONL snapshot
  handoff and sustained update/delete/replay. Independent Python SQLite checks
  compare 5,134 finite samples using their full binary64 bits and storage classes.
- Keep the verified compiler baseline at MoonBit `v0.10.15+943464bfa` (2026-10-12).

## 0.1.0 — 2026-10-14

- Persistent SQLite capture, consistent snapshots, retained consumer cursors.
- Atomic projection and restart recovery with lagging acknowledgement repair.
- Typed JSON/JSONL, bounded decoding, rechunking and adjacent-event compaction.
- Immutable filtered targets, audits, diagnostics and maintenance operations.
- Native CLI, independent process tests, reproducible CI and operational documentation.

Initial implementation. Metadata from intermediate development commits is not
compatibility-stable; reinitialize development databases before this version.
