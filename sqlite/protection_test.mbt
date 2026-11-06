///|
test "invalid UTF-8 initial data rejects snapshot without registering a consumer" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute(
    "INSERT INTO records VALUES(1,CAST(X'80C0AFEDA080' AS TEXT))",
    [],
  )
  |> ignore
  source.install_capture(["records"]) |> ignore
  assert_true(
    try {
      source.snapshot("must-not-register") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    source.query("SELECT count(*) FROM _mooncdc_consumers", [])[0].values,
    [Integer(0L)],
  )
  assert_eq(source.query("SELECT hex(value) FROM records", [])[0].values, [
    Text("80C0AFEDA080"),
  ])
  assert_eq(source.source_cursor().sequence, 0L)
}

///|
test "UTF-8 BOM NUL and emoji survive capture snapshots batches and auditing" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  let original = "\uFEFFA\u0000B😀尾"
  let updated = "\uFEFFchanged\u0000😀"
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("INSERT INTO records VALUES(1,?)", [Text(original)]) |> ignore
  source.install_capture(["records"]) |> ignore
  let snapshot = source.snapshot("unicode")
  assert_eq(snapshot.tables[0].rows[0].values, [Integer(1L), Text(original)])
  target.initialize_projection(@cdc.Snapshot::from_jsonl(snapshot.to_jsonl()))
  source.execute("UPDATE records SET value=? WHERE id=1", [Text(updated)])
  |> ignore
  assert_eq(@sqlite.synchronize(source, target, "unicode"), 1)
  assert_eq(target.query("SELECT value FROM records", [])[0].values, [
    Text(updated),
  ])
  assert_eq(
    source.query("SELECT hex(value) FROM records", []),
    target.query("SELECT hex(value) FROM records", []),
  )
  assert_true(@sqlite.audit_projection(source, target).consistent())
  target.execute("UPDATE records SET value=CAST(X'80' AS TEXT)", []) |> ignore
  assert_true(
    try {
      @sqlite.audit_projection(source, target) |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "SQLite REAL zero normalization is consistent for snapshots and later updates" {
  for declaration in ["BLOB", ""] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute(
      "CREATE TABLE records(id INTEGER PRIMARY KEY,value " +
      declaration +
      ",note TEXT)",
      [],
    )
    |> ignore
    source.execute("INSERT INTO records VALUES(1,?,'before')", [
      Real(0x8000000000000000UL.reinterpret_as_double()),
    ])
    |> ignore
    source.install_capture(["records"]) |> ignore
    let snapshot = source.snapshot("zeros")
    match snapshot.tables[0].rows[0].values[1] {
      Real(value) => assert_eq(value.reinterpret_as_uint64(), 0UL)
      _ => abort("Expected REAL zero")
    }
    target.initialize_projection(snapshot)
    source.execute("UPDATE records SET note='after' WHERE id=1", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "zeros"), 1)
    match target.query("SELECT value FROM records", [])[0].values[0] {
      Real(value) => assert_eq(value.reinterpret_as_uint64(), 0UL)
      _ => abort("Expected normalized REAL zero")
    }
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "non-finite REAL aborts a multirow source statement and its journal events" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value REAL)", [])
  |> ignore
  source.install_capture(["records"]) |> ignore
  assert_true(
    try {
      source.execute("INSERT INTO records VALUES(1,1.25),(2,1e999)", [])
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(source.query("SELECT * FROM records", []).is_empty())
  assert_true(source.query("SELECT * FROM _mooncdc_events", []).is_empty())
  assert_eq(source.source_cursor().sequence, 0L)
  source.execute("INSERT INTO records VALUES(1,1.25),(2,2.5)", []) |> ignore
  let before = source.source_cursor()
  assert_true(
    try {
      source.execute(
        "UPDATE records SET value=CASE id WHEN 1 THEN 3.0 ELSE -1e999 END",
        [],
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.source_cursor(), before)
  assert_eq(
    source.query("SELECT value FROM records ORDER BY id", [])[0].values,
    [Real(1.25)],
  )
}

///|
test "business triggers are refused before install and cannot contaminate later writes" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("CREATE TABLE effects(message TEXT)", []) |> ignore
  let trigger = "CREATE TRIGGER business AFTER INSERT ON records BEGIN INSERT INTO effects VALUES('must rollback'); END"
  source.execute(trigger, []) |> ignore
  assert_true(
    try {
      source.install_capture(["records"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    source
    .query("SELECT name FROM sqlite_schema WHERE name='_mooncdc_meta'", [])
    .is_empty(),
  )
  source.execute("DROP TRIGGER business", []) |> ignore
  source.install_capture(["records"]) |> ignore
  source.execute(trigger, []) |> ignore
  assert_true(
    try {
      source.verify_capture()
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.execute("INSERT INTO records VALUES(1,'new')", []) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(source.query("SELECT * FROM records", []).is_empty())
  assert_true(source.query("SELECT * FROM effects", []).is_empty())
  assert_true(source.query("SELECT * FROM _mooncdc_events", []).is_empty())
  assert_eq(source.source_cursor().sequence, 0L)
}

///|
test "known legacy capture upgrade preserves identity position and acknowledgements" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["records"]) |> ignore
  let snapshot = source.snapshot("existing")
  let table = snapshot.tables[0].schema
  for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
    source.execute(
      "DROP TRIGGER " + @cdc.quote_identifier(@cdc.trigger_name(1, operation)),
      [],
    )
    |> ignore
    source.execute(table.trigger_sql(1, operation, legacy_v020=true), [])
    |> ignore
  }
  source.execute("INSERT INTO records VALUES(1,'legacy')", []) |> ignore
  let cursor = source.source_cursor()
  source.execute(
    "UPDATE _mooncdc_consumers SET sequence=? WHERE name='existing'",
    [Integer(cursor.sequence)],
  )
  |> ignore
  let before_events = source.query("SELECT * FROM _mooncdc_events", [])
  assert_true(
    try {
      source.verify_capture()
      false
    } catch {
      _ => true
    },
  )
  let report = source.upgrade_capture()
  assert_eq(
    @cdc.integer_field(@cdc.field(report, "cursor"), "sequence"),
    cursor.sequence,
  )
  match @cdc.field(report, "upgraded_triggers") {
    Number(count, ..) => assert_eq(count, 3.0)
    _ => abort("Expected upgrade trigger count")
  }
  assert_eq(source.source_cursor(), cursor)
  assert_eq(source.consumer_cursor("existing"), cursor)
  assert_eq(source.retention_floor(), 0L)
  assert_eq(source.query("SELECT * FROM _mooncdc_events", []), before_events)
  source.verify_capture()
  match @cdc.field(source.upgrade_capture(), "upgraded_triggers") {
    Number(count, ..) => assert_eq(count, 0.0)
    _ => abort("Expected idempotent upgrade count")
  }
  source.execute("UPDATE records SET value='upgraded' WHERE id=1", []) |> ignore
  assert_eq(source.read_batch(cursor).events.length(), 1)
}

///|
test "non UTF-8 databases are rejected before capture or projection metadata is created" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("PRAGMA encoding='UTF-16le'", []) |> ignore
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  assert_true(
    try {
      source.install_capture(["records"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    source
    .query("SELECT name FROM sqlite_schema WHERE name='_mooncdc_meta'", [])
    .is_empty(),
  )
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  target.execute("PRAGMA encoding='UTF-16be'", []) |> ignore
  target.execute("CREATE TABLE existing(value TEXT)", []) |> ignore
  let snapshot : @cdc.Snapshot = {
    cursor: { source: "source", sequence: 0L, },
    tables: [
      {
        schema: {
          name: "records",
          columns: [
            {
              name: "id",
              declared_type: "INTEGER",
              required: true,
              key_position: 1,
            },
          ],
        },
        rows: [{ values: [Integer(1L)], }],
      },
    ],
  }
  assert_true(
    try {
      target.initialize_projection(snapshot)
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    target
    .query("SELECT name FROM sqlite_schema WHERE name='_mooncdc_projection'", [])
    .is_empty(),
  )
  assert_true(
    target
    .query("SELECT name FROM sqlite_schema WHERE name='records'", [])
    .is_empty(),
  )
  assert_eq(
    target
    .query("SELECT name FROM sqlite_schema WHERE name='existing'", [])
    .length(),
    1,
  )
}
