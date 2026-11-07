# Wire formats — MoonCDC 0.3.0

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
| Raw captured UTF-8 TEXT | `["text-utf8","efbbbf74657874"]` |
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
value representation. At the SQLite capture boundary, REAL zero is explicitly
normalized to positive zero by both snapshots and triggers, even when a BLOB or
untyped column retains negative zero. Only nonzero finite REAL values have a
bit-preservation guarantee across the database changefeed. Core wire encoding
continues to preserve signed zero, and audits compare normalized database values.

## TEXT bytes and compatibility

From 0.3.0 source triggers and table snapshots use `text-utf8` with the hexadecimal
bytes of TEXT before the binding can convert them to UTF-16. The decoder requires
strict UTF-8 and preserves an initial U+FEFF, embedded NUL and supplementary
characters. Invalid UTF-8 fails consumption/snapshot/audit before cursor advancement;
it is never silently replaced. Arbitrary bytes belong in BLOB, not TEXT.
Capture and projection databases must use SQLite UTF-8 encoding. Application
TEXT parameters are bound as UTF-8 bytes with SQL CAST parameter expressions, so
SQLite's UTF-16 BOM interpretation cannot strip a leading content character.

The public model and batch exporters continue to emit decoded `text` strings;
both tags are accepted. Old consumers cannot read raw `text-utf8` capture images.
Upgrade workers together and run `upgrade-capture` for intact 0.2.0 sources.

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

From 0.3.7 the default decoder allows 16,777,472 UTF-16 code units per line
and 67,108,864 units across the entire input. The line limit includes a 256-unit
margin above the source's default 16,777,216-unit event-body budget, covering
the event record envelope. If only a smaller total budget is supplied, the
implicit line limit is reduced to that total. Explicit line limits are never
increased and must be positive and no greater than the total budget. Callers
using larger source budgets must configure compatible decoder limits. CLI
`--max-input` independently counts UTF-8 file bytes rather than UTF-16 units.

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
