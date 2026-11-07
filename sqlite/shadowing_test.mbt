///|
test "TEMP target table cannot receive a batch while main cursors advance" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("INSERT INTO items VALUES(1,'old')", []) |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("replica")
  target.initialize_projection(snapshot)
  target.execute("CREATE TEMP TABLE ITEMS(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  target.execute("INSERT INTO temp.items VALUES(1,'old')", []) |> ignore
  source.execute("UPDATE main.items SET value='new'", []) |> ignore
  let batch = source.read_batch(snapshot.cursor)
  assert_true(
    try {
      target.apply_batch(batch) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @sqlite.synchronize(source, target, "replica") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(target.query("SELECT value FROM main.items", [])[0].values, [
    Text("old"),
  ])
  assert_eq(
    target.query("SELECT sequence FROM main._mooncdc_projection", [])[0].values,
    [Integer(0L)],
  )
  assert_eq(source.consumer_cursor("replica"), snapshot.cursor)
  target.execute("DROP TABLE temp.items", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "TEMP source view cannot supply snapshot rows or redirect consumer operations" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("INSERT INTO items VALUES(1,'authoritative')", []) |> ignore
  let start = source.install_capture(["items"])
  source.execute("CREATE TEMP VIEW items AS SELECT 99 AS id,'wrong' AS value", [])
  |> ignore
  assert_true(
    try {
      source.inspect_table("items") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.snapshot("new") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.read_batch(start) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    source.query("SELECT count(*) FROM main._mooncdc_consumers", [])[0].values,
    [Integer(0L)],
  )
  source.execute("DROP VIEW temp.items", []) |> ignore
  source.snapshot("replica") |> ignore
  source.execute(
    "CREATE TEMP TABLE _mooncdc_consumers(name TEXT,sequence INTEGER,paused INTEGER)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO temp._mooncdc_consumers VALUES('replica',0,0)", [])
  |> ignore
  assert_true(
    try {
      source.pause_consumer("replica", true)
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.drop_consumer("replica")
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.acknowledge("replica", start, start)
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    source.query("SELECT name,paused FROM main._mooncdc_consumers", [])[0].values,
    [Text("replica"), Integer(0L)],
  )
  source.execute("DROP TABLE temp._mooncdc_consumers", []) |> ignore
  source.execute(
    "CREATE TEMP VIEW _mooncdc_meta AS SELECT * FROM main._mooncdc_meta",
    [],
  )
  |> ignore
  assert_true(
    try {
      source.source_cursor() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.prune() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.prune_bounded(1) |> ignore
      false
    } catch {
      _ => true
    },
  )
  source.execute("DROP VIEW temp._mooncdc_meta", []) |> ignore
  assert_eq(source.consumer_cursor("replica"), start)
}

///|
test "initialization rejects TEMP shadows without creating persistent metadata" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("CREATE TEMP TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  assert_true(
    try {
      source.install_capture(["items"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_false(source.has_object("_mooncdc_meta"))
  source.execute("DROP TABLE temp.items", []) |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("replica")
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  target.execute("CREATE TEMP VIEW items AS SELECT 2 AS id,'shadow' AS value", [])
  |> ignore
  assert_true(
    try {
      target.initialize_projection(snapshot)
      false
    } catch {
      _ => true
    },
  )
  assert_false(target.has_object("_mooncdc_projection"))
  target.execute("DROP VIEW temp.items", []) |> ignore
  // Unrelated TEMP staging tables remain usable and cannot shadow captured data.
  target.execute("CREATE TEMP TABLE staging(value TEXT)", []) |> ignore
  target.initialize_projection(snapshot)
  source.execute("INSERT INTO main.items VALUES(1,'new')", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "main and TEMP tables named pragma_table_list cannot spoof table inspection" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute(
    "CREATE TABLE pragma_table_list(schema TEXT,name TEXT,type TEXT)",
    [],
  )
  |> ignore
  source.execute(
    "INSERT INTO main.pragma_table_list VALUES('main','items','virtual')",
    [],
  )
  |> ignore
  source.execute(
    "CREATE TEMP TABLE pragma_table_list(schema TEXT,name TEXT,type TEXT)",
    [],
  )
  |> ignore
  source.execute(
    "INSERT INTO temp.pragma_table_list VALUES('main','items','shadow')",
    [],
  )
  |> ignore
  assert_eq(source.inspect_table("items").name, "items")
  source.install_capture(["items"]) |> ignore
  source.execute("INSERT INTO main.items VALUES(1,'real table')", []) |> ignore
  let snapshot = source.snapshot("replica")
  assert_eq(snapshot.tables[0].rows[0].values, [Integer(1L), Text("real table")])
}
