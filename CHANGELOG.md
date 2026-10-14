# Changelog

## 0.1.0 — 2026-10-14

- Persistent SQLite capture, consistent snapshots, retained consumer cursors.
- Atomic projection and restart recovery with lagging acknowledgement repair.
- Typed JSON/JSONL, bounded decoding, rechunking and adjacent-event compaction.
- Immutable filtered targets, audits, diagnostics and maintenance operations.
- Native CLI, independent process tests, reproducible CI and operational documentation.

Initial implementation. Metadata from intermediate development commits is not
compatibility-stable; reinitialize development databases before this version.
