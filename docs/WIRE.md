# Wire formats — MoonCDC 0.2.0

Cursors contain a `source` identity and nonnegative decimal-string `sequence`.
Events contain positive decimal-string sequence, table, operation, before/after.
Insert has only after, delete only before, update both images.

Rows are arrays in schema column order. Values use tagged arrays:

| Class | Example |
| --- | --- |
| NULL | `["null"]` |
| INTEGER | `["integer","9223372036854775807"]` |
| REAL | `["real","1","-3"]` (0.125) |
| TEXT | `["text","text"]` |
| BLOB | `["blob","00ff"]` |

## Exact REAL representation

From 0.2.0, a REAL has three string elements:
`["real","signed significand","binary exponent"]`. Its exact value is the
signed integer significand multiplied by two raised to the integral exponent.
For example, `["real","1681218273811815","946"]` encodes the binary64 value
normally written as `1e300`. The integer strings are parsed without passing through
JSON floating-point numbers. INTEGER and REAL remain distinct storage classes.

The core encoder extracts the IEEE-754 bits directly and removes trailing binary
zeros from the significand. The decoder constructs the bits directly, accepting
only exactly representable finite binary64 pairs. It rejects overflow, excessive
significand width and pairs requiring subnormal rounding; it never substitutes an
approximate value. Equivalent exact significand/exponent pairs may have different
spellings. Zero uses exponent zero; `["real","-0","0"]` preserves negative zero
in the core wire model.

Persistent SQLite capture triggers derive the pair using eleven fixed stages of
exact power-of-two scaling. Factors are built by repeatedly squaring `2.0`, and
the final integral significand is converted to an integer string. The trigger
requires no connection-local custom functions, floating decimal formatting or
floating decimal parsing. JSON/JSONL snapshot encoders use the same three-element
value representation. At the database boundary the actual SQLite storage value
is authoritative; SQLite can normalize negative zero to positive zero.

The decoder still accepts the 0.1.0 two-element `["real","decimal"]` form for
reading existing files. That compatibility cannot recover digits already lost
by old capture triggers or targets. Version 0.1.0 readers cannot decode the new
three-element REAL form, so upgrade all consumers. Capture triggers from 0.1.0
fail 0.2.0 verification and require reinitialization as described in
[Operations](OPERATIONS.md#upgrading-from-010-to-020).

## Batch

JSON `mooncdc.batch.v1` carries start, end, high_water (string) and events.
The envelope names remain unchanged; the REAL value encoding is extended in 0.2.0.
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
