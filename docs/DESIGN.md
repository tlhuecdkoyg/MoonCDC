# Design contract

## Scope

Capture persistent AFTER INSERT/UPDATE/DELETE triggers on explicitly selected
ordinary SQLite tables. A durable source identity and monotonic event sequence
identify changes. Primary keys must be explicit and non-null; changes to primary
keys are represented by before/after row images. SQLite values preserve their
storage classes, including 64-bit integers and BLOBs.

The source database contains metadata and a typed change journal. Installation,
schema inspection and trigger creation occur under a write transaction. Rolled
back source mutations must not leave committed events.

## Initialization and delivery

A full snapshot and its high-water mark are read within one SQLite transaction.
New consumers must initialize from a snapshot; the snapshot watermark establishes
where incremental replay begins. A bounded incremental batch contains ordered
events and an explicit start/end cursor. A cursor is tied to a source identity.

SQLite projections update rows and their local cursor in the same target
transaction. Retrying the same batch must not apply it twice. A source-side
acknowledgement is separate and may lag: a crash after target commit is recovered
by consulting the target cursor, not by repeating side effects unconditionally.

JSONL export provides at-least-once delivery. External consumers persist their
effects before acknowledging a cursor. No cross-system exactly-once guarantee.

## Boundaries

Events are row-level. Arbitrary source transaction boundaries are not recovered
from row triggers. Intermediate target batches need not reproduce cross-row
source transaction atomicity. The product is a changefeed and eventual projection,
not a transparent database replication system.

DDL changes require explicit reconfiguration and reinitialization. Unknown schema
changes, missing capture triggers, invalid cursors and truncated logs fail closed.
No bidirectional merge, WAL decoding, virtual tables, hidden-rowid keys, arbitrary
remote databases, or automatic schema migration in version 0.1.

## Validation gates

Independent Python sqlite3 writes must be captured by MoonBit. Tests cover rollback,
external connections, snapshot handoff, deletion, key changes, NULL and BLOB data,
replay, target divergence, schema drift, retention and stale consumer cursors.
Subprocess termination at durable phase boundaries must leave recoverable state.
CI must run on Windows and Linux with pinned toolchain and dependencies.

Production line accounting excludes tests, generated interfaces, dependencies,
examples, comments and blank lines. Commits represent complete engineering steps.
