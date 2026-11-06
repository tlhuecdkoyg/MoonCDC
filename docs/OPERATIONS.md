# Operations

Abbreviate `moon run cmd/main --target native --` as `mooncdc` below. Errors go
to stderr with exit 2. Successful reports use exit 0; inspect `consistent`,
`healthy`, `eligible` or `applicable` in their JSON for the reported condition.

## Initialize and resume

Configure every writer with `PRAGMA recursive_triggers=ON`. Run `plan SOURCE
TABLE...`, then `install SOURCE TABLE...` once. Use `bootstrap SOURCE NEW_TARGET
CONSUMER` once and `sync SOURCE TARGET CONSUMER` repeatedly. Default sync processes
at most 100 batches of 1,000 events; compare returned watermarks for remaining lag.
Never share a consumer between independently progressing targets.

`status SOURCE` reports retained events and consumers; `target-status TARGET`
reports target cursor, plan and row counts.

## Upgrading from 0.1.0 to 0.2.0

Version 0.1.0 encoded captured REAL values through SQLite decimal formatting.
Some values, including `1e300`, were changed by that conversion. A target initialized
from a directly read snapshot could then disagree with the rounded before-image
of a later ordinary update. Version 0.2.0 replaces that path with exact binary
significand/exponent encoding and keeps strict before-image checks.

This changes the installed capture trigger SQL. The new verifier intentionally
rejects old triggers; replacing just the executable is not a migration. Reading
legacy two-element decimal REAL records is supported, but cannot recover precision
already lost in old journals or projections. Do not suppress conflicts, compare
with a tolerance, or advance a consumer over an unprocessed interval.

Use a new capture generation and a fresh snapshot:

1. Stop application writes and all sync workers. Take verified, consistent backups
   of the old source and targets, retaining the old executable and consumer positions.
   If 0.1.0 can still process pending changes safely, finish and audit them before
   retiring that stream. If it encounters the reported conflict, retain the old
   source, journal and target for investigation rather than skipping the event.
2. Create a **new SQLite database** containing the intended user tables and their
   current data from the authoritative source. Copy the required user schema,
   indexes, constraints and business triggers deliberately; exclude every
   `_mooncdc_*` metadata object and capture trigger. A whole-database backup alone
   is not this new source because it retains the old capture objects. Verify user
   data and application behavior in the new database. Preserve the original database
   and backup; these steps do not require deleting either one.
3. With 0.2.0, run `plan` and `install` against the new source. Configure every
   application writer with `PRAGMA recursive_triggers=ON`. Generate any filtered
   plan again from the new source schema, and review its selections and predicates.
4. Run `bootstrap` with a **new consumer name and a new target path**. This creates
   a fresh snapshot and cursor for the new source identity. Do not reuse old cursors,
   append new events to an old journal, or reuse the damaged target.
5. Run `sync` and `audit` (with `--plan` for a filtered target). Confirm matching
   watermarks and data before switching the application and downstream consumers
   to the new source/target generation. Keep old backups according to your retention
   policy. Resume writes and continue normal sync only after the switch is verified.

For example, after preparing and checking `source-v020.db` from user data:

```sh
mooncdc plan source-v020.db orders customers
mooncdc install source-v020.db orders customers
mooncdc bootstrap source-v020.db report-v020.db reporting-v020
mooncdc sync source-v020.db report-v020.db reporting-v020
mooncdc audit source-v020.db report-v020.db
```

If the old source was itself modified after incorrect data was fed back from a
projection, recover authoritative user data from a trusted backup or application
record first. New encoding cannot reconstruct historical values absent from the
source and its backups.

## Offline transport

### Upgrading intact 0.2.0 sources to 0.3.0

Stop writers and workers, back up databases, then run
`upgrade-capture SOURCE --limit 100000`. The limit must cover all retained events.
The command acquires a write transaction, verifies exact known trigger definitions,
table definitions, UTF-8 database encoding and retained journal decodability, then
replaces triggers atomically. Source identity, event sequence, floor, journal and
consumer acknowledgements remain unchanged; repeating the command is harmless.
Use 0.3.0 for every worker after the upgrade, since new captured TEXT uses a new tag.

Unknown or missing triggers, additional business triggers, schema drift and invalid
retained events abort the upgrade without partial changes. This is not a repair
tool for already lost precision, invalid text or arbitrary schema edits. Such
sources require a reviewed migration/new snapshot from authoritative user data.
Version 0.1.0 must still follow the fresh-generation migration above.

Only UTF-8 databases with valid Unicode TEXT are supported. Invalid UTF-8 detected
in historical/external writes stops snapshots, consumption and audits; use a new
reviewed snapshot after correcting source data rather than skipping journal events.
Do not install other triggers on captured tables. Newly added triggers are detected
in the persistent main schema and protected writes abort; their business effects
must be reviewed separately. Do not install connection-local TEMP business triggers
either: persistent main triggers cannot fully inspect that private schema, so this
restriction must be enforced by the application managing writer connections.

Version 0.3.1 changes only parameter-expression semantics and table-kind inspection;
an intact 0.3.0 source needs no further capture upgrade. The 0.2.0 upgrade command
and the 0.1.0 fresh-snapshot procedure remain as described above.

SQLite REAL zero is normalized to +0.0 in snapshots and captured images, including
BLOB/untyped columns that retain negative zero. Audits intentionally consider these
zeros equivalent. If retaining the IEEE sign of zero is an application requirement,
store that value as BLOB or an explicit domain representation rather than REAL.

```sh
mooncdc snapshot source.db offline --format jsonl --output snapshot.jsonl
mooncdc init target.db --format jsonl --input snapshot.jsonl
mooncdc export source.db offline --format jsonl --output batch.jsonl
mooncdc preview target.db --format jsonl --input batch.jsonl
mooncdc apply target.db --format jsonl --input batch.jsonl
mooncdc ack source.db offline --format jsonl --input batch.jsonl
```

Export never acknowledges. Ack only after effects are durably committed. Output
files must not exist. `--input -` reads stdin. JSONL needs a commit trailer even
with zero events. Persist the complete output before using it for recovery.

## Filtered targets

```sh
mooncdc make-plan source.db --output projection.json
# Edit the plan, preserving all primary key columns.
mooncdc bootstrap source.db subset.db subset --plan projection.json
mooncdc sync source.db subset.db subset --plan projection.json
mooncdc audit source.db subset.db --plan projection.json
```

Each rule contains source schema, target name, selected columns and filter.
Example predicates:

```json
{"op":"equal","column":"active","value":["integer","1"]}
```

```json
{"op":"all","children":[{"op":"integer_between","column":"id","lower":"1","upper":"100"},{"op":"prefix","column":"name","prefix":"A"}]}
```

Other operators: `always`, `null`, `any`, `not` with `child`. No SQL type coercion.
Maximum nesting is 32; each all/any node allows 64 children. Stored plan comparison
includes predicates, columns and source schema. Changing a plan requires a new target.

Bound-target `apply --plan` and `preview --plan` accept RAW source batches.
`project-snapshot` and `project-batch` are separate utilities for external consumers;
do not transform twice. Those output files alone do not carry a durable rule lock.

## Recovery

| Failure | Action |
| --- | --- |
| Exit before target commit | Retry sync; SQLite rolls back the target transaction |
| Target committed, source ack missing | Retry sync; target cursor repairs source ack |
| Old batch replay | Target skips an already committed end cursor |
| Target changed externally | Preview/apply rejects before-image conflicts; audit detects other changes; restore or reinitialize |
| Missing trigger / changed DDL | Diagnose, stop consumers, initialize a new generation; recreating a trigger cannot recover missing events |
| Cursor below retained floor | New snapshot and new consumer; guessing a cursor does not reconstruct data |
| Snapshot output failure | Check completeness; explicitly drop new consumer and retry if necessary |
| Bootstrap failure | Inspect consumer and target; source registration and target initialization are separate transactions; use a new destination |

Pause still pins retention. `retention SOURCE` shows safe pruning and blockers.
`prune-bounded SOURCE --limit N` removes at most N acknowledged contiguous events.
`prune` removes all safely acknowledged events. Dropping a consumer releases its pin.

`fork-consumer SOURCE OLD NEW` copies only a cursor; clone the target separately
under coordinated writes. `restore-consumer SOURCE NAME --input CURSOR_FILE`
requires an existing materialized state corresponding to that retained checkpoint.
Neither operation creates target data.

To uninstall: drain consumers, prune events, drop consumers explicitly, then run
`uninstall SOURCE SOURCE_ID`. The identity must match; remaining consumers or
events prevent uninstall. User tables remain intact.

## Audits and budgets

`verify SOURCE --limit N` audits ALL retained events and fails on exceeding N
(CLI default 1,000). `diagnose SOURCE` collects schema/trigger problems and runs
SQLite quick_check. `audit SOURCE TARGET` requires equal watermarks rather than
mislabeling lag as corruption; default row budget is 100,000.

Preview takes a write lock, applies events and always rolls back. Actual apply
validates again because another writer may change data after preview. Snapshots,
audits and batches are bounded in-memory operations, not unlimited streaming backups.
