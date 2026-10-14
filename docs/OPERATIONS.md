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

## Offline transport

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
