# MoonCDC

MoonCDC means **MoonBit Change Data Capture**. It captures committed row changes
from existing SQLite tables and supports resumable, one-way projections.

Implementation is in progress. See [the design contract](docs/DESIGN.md) for the
intended guarantees and limits. Features are documented as usable only after
their real SQLite integration checks pass.

The implementation will provide a reusable MoonBit library and a native CLI.
SQLite is reused through `moonbit-community/sqlite3`; the database engine is not
reimplemented or counted as MoonCDC production code.
