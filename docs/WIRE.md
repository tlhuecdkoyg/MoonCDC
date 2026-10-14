# Wire format v1

Cursors contain a `source` identity and nonnegative decimal-string `sequence`.
Events contain positive decimal-string sequence, table, operation, before/after.
Insert has only after, delete only before, update both images.

Rows are arrays in schema column order. Values use tagged arrays:

| Class | Example |
| --- | --- |
| NULL | `["null"]` |
| INTEGER | `["integer","9223372036854775807"]` |
| REAL | `["real","0.12345678901234567"]` |
| TEXT | `["text","text"]` |
| BLOB | `["blob","00ff"]` |

Only finite REAL values are supported. Capture uses SQLite `%!.26g`, avoiding
default SQLite JSON floating precision loss. Integer 1 and real 1 remain distinct.

## Batch

JSON `mooncdc.batch.v1` carries start, end, high_water (string) and events.
Events must strictly increase within `(start,end]`; high_water must be at least
end.sequence. Filtering or compaction can remove events while retaining the interval.
An empty batch may therefore advance a target.

JSONL consists of a header (`kind: header`, `format: mooncdc.jsonl.v1`, start,
high_water), event records (`kind: event`, event object), and mandatory trailer
(`kind: commit`, end, decimal-string count). Duplicate headers, post-commit records,
bad ordering/images/count and missing commit are errors. BatchDecoder accepts String
chunks, caps lines and total input, and is unusable after failure or finish.

Split/merge preserve intervals. Adjacent compaction removes intermediate changes
of the same row; different rows and key changes are ordering barriers. Use it for
final-state projection, not historical audit.

## Snapshot

JSON `mooncdc.snapshot.v1` carries cursor and table snapshots. JSONL
`mooncdc.snapshot-jsonl.v1` uses a snapshot header (cursor, schemas), row records
(table, row), then a count-bearing commit. Unknown tables, duplicate identities,
invalid widths, null keys and missing commit fail. Snapshots are bounded in memory.

## Trust

Formats validate structure, not authenticity; use trusted files or authenticated
transport. Acknowledgement asserts the consumer durably processed the interval;
MoonCDC cannot verify arbitrary external side effects. No source transaction grouping
is implied by a batch.
