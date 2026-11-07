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

Source high-water marks consider both main.sqlite_sequence and the maximum retained
event sequence. SQLite FAIL conflicts can commit earlier row changes and trigger
events without finishing the AUTOINCREMENT bookkeeping for that statement. Before
pruning, persist the observed high-water mark in main.sqlite_sequence inside the
same write transaction so deleting the last retained row cannot reuse a sequence.

JSONL export provides at-least-once delivery. External consumers persist their
effects before acknowledging a cursor. No cross-system exactly-once guarantee.

## Boundaries

Events are row-level. Arbitrary source transaction boundaries are not recovered
from row triggers. Intermediate target batches need not reproduce cross-row
source transaction atomicity. The product is a changefeed and eventual projection,
not a transparent database replication system.

Foreign-key ON UPDATE CASCADE, SET NULL and SET DEFAULT actions must not form a
table-level cycle that returns to a captured table. A nested action can update the
outer row before its AFTER trigger records the outer change, breaking sequential
before-image replay. The check is conservative, includes uncaptured intermediate
tables, and depends on schema rather than the current row contents. NO ACTION and
RESTRICT update actions, acyclic cascades and pure DELETE CASCADE cycles are not
rejected by this rule. Installation and each capture verification enforce this boundary.

Also reject a path starting with deletion of a captured table and returning to
that table with an update of a primary-key column. Follow DELETE CASCADE as another
delete, DELETE SET NULL/SET DEFAULT as an update, and then any mutating ON UPDATE
actions. The outer deletion is recorded after nested actions, so an inner update
can otherwise reuse a key still present in the projection. This state/column check
includes uncaptured tables while preserving safe non-key self-references.

DDL changes require explicit reconfiguration and reinitialization. Unknown schema
changes, missing capture triggers, invalid cursors and truncated logs fail closed.
No bidirectional merge, WAL decoding, virtual tables, hidden-rowid keys, arbitrary
remote databases, or automatic schema migration in version 0.1.

## Validation gates

CDC operations reject TEMP tables/views that would shadow captured/projected
main objects or reserved metadata. Internal PRAGMA reads that enforce capture
safety must use function-call syntax; a regular table cannot stand in for a
table-valued PRAGMA. Source connections without recursive triggers remain
unsupported, and a namespace collision must fail before any source write commits.

Independent Python sqlite3 writes must be captured by MoonBit. Tests cover rollback,
external connections, snapshot handoff, deletion, key changes, NULL and BLOB data,
replay, target divergence, schema drift, retention and stale consumer cursors.
Subprocess termination at durable phase boundaries must leave recoverable state.
CI must run on Windows and Linux with pinned toolchain and dependencies.

Production line accounting excludes tests, generated interfaces, dependencies,
examples, comments and blank lines. Commits represent complete engineering steps.
