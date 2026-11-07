///|
fn before_text_state(
  source : @sqlite.Database,
  target : @sqlite.Database,
  cursor : @cdc.Cursor,
  encoded : String,
) -> Unit raise {
  assert_eq(target.projection_cursor(), cursor)
  assert_eq(source.consumer_cursor("replica"), cursor)
  assert_eq(target.query("SELECT hex(value),note FROM items", [])[0].values, [
    Text(encoded),
    Text("before"),
  ])
}

///|
test "before-image comparison rejects invalid UTF-8 rather than accepting its transcoded value" {
  for
    (encoded, original) in [
      ("80", "\u0080"),
      ("C0AF", "\uFFFD"),
      ("EDA080", "\uFFFD"),
      ("FF", "\uFFFD"),
    ] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute(
      "CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT,note TEXT)",
      [],
    )
    |> ignore
    source.execute("INSERT INTO items VALUES(1,?,'before')", [Text(original)])
    |> ignore
    source.install_capture(["items"]) |> ignore
    let snapshot = source.snapshot("replica")
    target.initialize_projection(snapshot)
    target.execute("UPDATE items SET value=CAST(X'" + encoded + "' AS TEXT)", [])
    |> ignore
    source.execute("UPDATE items SET note='after'", []) |> ignore
    let batch = source.read_batch(snapshot.cursor)
    let preview = target.preview_batch(batch)
    assert_false(@cdc.boolean_field(preview, "applicable"))
    assert_true(@cdc.string_field(preview, "error").contains("UTF-8"))
    before_text_state(source, target, snapshot.cursor, encoded)
    assert_true(
      try {
        target.apply_batch(batch) |> ignore
        false
      } catch {
        _ => true
      },
    )
    before_text_state(source, target, snapshot.cursor, encoded)
    assert_true(
      try {
        @sqlite.synchronize(source, target, "replica") |> ignore
        false
      } catch {
        _ => true
      },
    )
    before_text_state(source, target, snapshot.cursor, encoded)
    target.execute("UPDATE items SET value=?", [Text(original)]) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
    source.execute("DELETE FROM items", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "invalid target UTF-8 on a DELETE rolls back an already applied batch prefix" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute(
    "CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT,note TEXT)",
    [],
  )
  |> ignore
  source.execute(
    "INSERT INTO items VALUES(1,'prefix','before'),(2,?,'before')",
    [Text("\u0080")],
  )
  |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("replica")
  target.initialize_projection(snapshot)
  target.execute("UPDATE items SET value=CAST(X'80' AS TEXT) WHERE id=2", [])
  |> ignore
  source.execute("UPDATE items SET note='after' WHERE id=1", []) |> ignore
  source.execute("DELETE FROM items WHERE id=2", []) |> ignore
  let batch = source.read_batch(snapshot.cursor)
  let preview = target.preview_batch(batch)
  assert_false(@cdc.boolean_field(preview, "applicable"))
  assert_eq(@cdc.integer_field(preview, "sequence"), 2L)
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
  assert_eq(
    target.query("SELECT id,hex(value),note FROM items ORDER BY id", [])[0].values,
    [Integer(1L), Text("707265666978"), Text("before")],
  )
  assert_eq(
    target.query("SELECT hex(value),note FROM items WHERE id=2", [])[0].values,
    [Text("80"), Text("before")],
  )
  assert_eq(target.projection_cursor(), snapshot.cursor)
  assert_eq(source.consumer_cursor("replica"), snapshot.cursor)
  target.execute("UPDATE items SET value=? WHERE id=2", [Text("\u0080")])
  |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "filtered before-images use raw UTF-8 with quoted tables and composite Unicode keys" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  let source_name = "odd \"items"
  let target_name = "visible \"items"
  let source_sql = @cdc.quote_identifier(source_name)
  let target_sql = @cdc.quote_identifier(target_name)
  let key = "\uFEFFtenant\u0000😀"
  let next_key = "\uFEFFnext\u0000😀"
  let updated = "\uFEFFvalue\u0000😀"
  source.execute(
    "CREATE TABLE " +
    source_sql +
    "(tenant TEXT,id INTEGER,value TEXT,note TEXT,PRIMARY KEY(tenant,id))",
    [],
  )
  |> ignore
  source.execute("INSERT INTO " + source_sql + " VALUES(?,1,?,'visible')", [
    Text(key),
    Text("\u0080"),
  ])
  |> ignore
  source.install_capture([source_name]) |> ignore
  let snapshot = source.snapshot("filtered")
  let schema = snapshot.tables[0].schema
  let plan = @cdc.ProjectionPlan::{
    rules: [
      {
        source: schema,
        target: target_name,
        columns: schema.columns.map(column => @cdc.ColumnSelection::{
          source: column.name,
          target: column.name,
        }),
        filter: Equal("note", Text("visible")),
      },
    ],
  }
  target.initialize_filtered_projection(snapshot, plan)
  target.execute("UPDATE " + target_sql + " SET value=CAST(X'80' AS TEXT)", [])
  |> ignore
  source.execute("UPDATE " + source_sql + " SET value=?", [Text(updated)])
  |> ignore
  let batch = source.read_batch(snapshot.cursor)
  assert_false(
    @cdc.boolean_field(
      target.preview_batch(batch, plan=Some(plan)),
      "applicable",
    ),
  )
  assert_true(
    try {
      target.apply_filtered_batch(batch, plan) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @sqlite.synchronize_filtered(source, target, "filtered", plan) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(target.projection_cursor(), snapshot.cursor)
  assert_eq(source.consumer_cursor("filtered"), snapshot.cursor)
  assert_eq(
    target.query("SELECT hex(value) FROM " + target_sql, [])[0].values,
    [Text("80")],
  )
  target.execute("UPDATE " + target_sql + " SET value=?", [Text("\u0080")])
  |> ignore
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 1)
  assert_eq(
    source.query("SELECT hex(value) FROM " + source_sql, []),
    target.query("SELECT hex(value) FROM " + target_sql, []),
  )
  source.execute("UPDATE " + source_sql + " SET tenant=?", [Text(next_key)])
  |> ignore
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 1)
  assert_true(
    @sqlite.audit_filtered_projection(source, target, plan).consistent(),
  )
  source.execute("DELETE FROM " + source_sql, []) |> ignore
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 1)
  assert_true(
    @sqlite.audit_filtered_projection(source, target, plan).consistent(),
  )
}
