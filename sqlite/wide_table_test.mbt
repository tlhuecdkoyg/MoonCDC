///|
test "0.3.1 narrow capture guard upgrades without resetting pending events" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("replica")
  target.initialize_projection(snapshot)
  for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
    source.execute(
      "DROP TRIGGER " + @cdc.quote_identifier(@cdc.trigger_name(1, operation)),
      [],
    )
    |> ignore
    source.execute(
      snapshot.tables[0].schema.trigger_sql(1, operation, legacy_v031=true),
      [],
    )
    |> ignore
  }
  source.execute("INSERT INTO items VALUES(1,'pending')", []) |> ignore
  let cursor = source.source_cursor()
  assert_eq(
    @cdc.field(source.upgrade_capture(), "upgraded_triggers"),
    Json::number(3),
  )
  assert_eq(source.source_cursor(), cursor)
  assert_eq(source.consumer_cursor("replica"), snapshot.cursor)
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "128 column legacy capture upgrade preserves journal and consumer state" {
  for legacy_v020 in [false, true] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    let names = Array::makei(128, index => "c" + index.to_string())
    source.execute(
      "CREATE TABLE wide(" + names.join(",") + ",PRIMARY KEY(c0))",
      [],
    )
    |> ignore
    source.install_capture(["wide"]) |> ignore
    let snapshot = source.snapshot("existing")
    target.initialize_projection(snapshot)
    let table = snapshot.tables[0].schema
    for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
      source.execute(
        "DROP TRIGGER " + @cdc.quote_identifier(@cdc.trigger_name(1, operation)),
        [],
      )
      |> ignore
      source.execute(
        table.trigger_sql(1, operation, legacy_v020~, legacy_v031=!legacy_v020),
        [],
      )
      |> ignore
    }
    let row = @cdc.Row::{
      values: Array::makei(128, index => {
        if index == 0 {
          @cdc.Value::Integer(1L)
        } else if index == 127 {
          @cdc.Value::Real(1.0e300)
        } else {
          @cdc.Value::Text("before")
        }
      }),
    }
    let statement = table.insert_statement(row)
    source.execute(statement.sql, statement.parameters) |> ignore
    let cursor = source.source_cursor()
    let journal_sql = "SELECT * FROM _mooncdc_events ORDER BY sequence"
    let journal = source.query(journal_sql, [])
    assert_true(
      try {
        source.verify_capture()
        false
      } catch {
        _ => true
      },
    )
    assert_eq(
      @cdc.field(source.upgrade_capture(), "upgraded_triggers"),
      Json::number(3),
    )
    assert_eq(source.query(journal_sql, []), journal)
    assert_eq(source.source_cursor(), cursor)
    assert_eq(source.consumer_cursor("existing"), snapshot.cursor)
    assert_eq(
      @cdc.field(source.upgrade_capture(), "upgraded_triggers"),
      Json::number(0),
    )
    assert_eq(@sqlite.synchronize(source, target, "existing"), 1)
    source.execute("UPDATE wide SET c1=?,c127=? WHERE c0=1", [
      Text("\uFEFFafter\u0000😀"),
      Real(-1.0e300),
    ])
    |> ignore
    assert_eq(@sqlite.synchronize(source, target, "existing"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
    source.execute("DELETE FROM wide", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "existing"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}
