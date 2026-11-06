///|
fn install_review_legacy_triggers(
  source : @sqlite.Database,
  table : @cdc.Table,
) -> Unit raise {
  for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
    source.execute(
      "DROP TRIGGER " + @cdc.quote_identifier(@cdc.trigger_name(1, operation)),
      [],
    )
    |> ignore
    source.execute(table.trigger_sql(1, operation, legacy_v020=true), [])
    |> ignore
  }
}

///|
test "upgrade audit budget failure preserves all legacy capture state before retry" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["records"]) |> ignore
  let snapshot = source.snapshot("existing")
  install_review_legacy_triggers(source, snapshot.tables[0].schema)
  source.execute("INSERT INTO records VALUES(1,'one'),(2,'two')", []) |> ignore
  let triggers_sql = "SELECT name,sql FROM sqlite_schema WHERE type='trigger' ORDER BY name"
  let before_triggers = source.query(triggers_sql, [])
  let before_events = source.query(
    "SELECT * FROM _mooncdc_events ORDER BY sequence",
    [],
  )
  let before_meta = source.query("SELECT * FROM _mooncdc_meta", [])
  let before_cursor = source.source_cursor()
  let before_ack = source.consumer_cursor("existing")
  let before_floor = source.retention_floor()
  assert_true(
    try {
      source.upgrade_capture(max_events=1) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.query(triggers_sql, []), before_triggers)
  assert_eq(
    source.query("SELECT * FROM _mooncdc_events ORDER BY sequence", []),
    before_events,
  )
  assert_eq(source.query("SELECT * FROM _mooncdc_meta", []), before_meta)
  assert_eq(source.source_cursor(), before_cursor)
  assert_eq(source.consumer_cursor("existing"), before_ack)
  assert_eq(source.retention_floor(), before_floor)
  let report = source.upgrade_capture(max_events=2)
  match @cdc.field(report, "upgraded_triggers") {
    Number(count, ..) => assert_eq(count, 3.0)
    _ => abort("Expected upgraded trigger count")
  }
  source.verify_capture()
  assert_eq(source.source_cursor(), before_cursor)
  assert_eq(source.consumer_cursor("existing"), before_ack)
  assert_eq(source.retention_floor(), before_floor)
  assert_eq(
    source.query("SELECT * FROM _mooncdc_events ORDER BY sequence", []),
    before_events,
  )
}

///|
test "upgrade rejects corrupt retained images and unknown trigger SQL without replacing evidence" {
  for fault in ["corrupt-image", "unknown-trigger"] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
    |> ignore
    source.install_capture(["records"]) |> ignore
    let snapshot = source.snapshot("existing")
    let table = snapshot.tables[0].schema
    install_review_legacy_triggers(source, table)
    source.execute("INSERT INTO records VALUES(1,'one'),(2,'two')", [])
    |> ignore
    if fault == "corrupt-image" {
      source.execute(
        "UPDATE _mooncdc_events SET after_row='not-json' WHERE sequence=2",
        [],
      )
      |> ignore
    } else {
      source.execute(
        "DROP TRIGGER " +
        @cdc.quote_identifier(@cdc.trigger_name(1, @cdc.Update)),
        [],
      )
      |> ignore
      let unknown = table
        .trigger_sql(1, @cdc.Update, legacy_v020=true)
        .replace_all(old=" BEGIN ", new=" BEGIN SELECT 42; ")
      source.execute(unknown, []) |> ignore
    }
    let triggers_sql = "SELECT name,sql FROM sqlite_schema WHERE type='trigger' ORDER BY name"
    let before_triggers = source.query(triggers_sql, [])
    let before_events = source.query(
      "SELECT * FROM _mooncdc_events ORDER BY sequence",
      [],
    )
    let before_meta = source.query("SELECT * FROM _mooncdc_meta", [])
    let before_cursor = source.source_cursor()
    let before_ack = source.consumer_cursor("existing")
    let before_floor = source.retention_floor()
    assert_true(
      try {
        source.upgrade_capture(max_events=100) |> ignore
        false
      } catch {
        _ => true
      },
    )
    assert_eq(source.query(triggers_sql, []), before_triggers)
    assert_eq(
      source.query("SELECT * FROM _mooncdc_events ORDER BY sequence", []),
      before_events,
    )
    assert_eq(source.query("SELECT * FROM _mooncdc_meta", []), before_meta)
    assert_eq(source.source_cursor(), before_cursor)
    assert_eq(source.consumer_cursor("existing"), before_ack)
    assert_eq(source.retention_floor(), before_floor)
  }
}
