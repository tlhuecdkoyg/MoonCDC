///|
fn prune_failed_statement_history(
  source : @sqlite.Database,
  bounded : Bool,
  events : Int32,
) -> Unit raise {
  if bounded {
    for _ in 0..<events {
      assert_eq(source.prune_bounded(1), 1L)
    }
    assert_eq(source.prune_bounded(1), 0L)
  } else {
    assert_eq(source.prune(), events.to_int64())
  }
  assert_eq(
    source.query(
      "SELECT seq FROM main.sqlite_sequence WHERE name='_mooncdc_events'",
      [],
    )[0].values,
    [Integer(events.to_int64())],
  )
  assert_eq(source.source_cursor().sequence, events.to_int64())
  assert_true(
    source.query("SELECT sequence FROM main._mooncdc_events", []).is_empty(),
  )
}

///|
test "INSERT OR FAIL committed prefix has a watermark without sqlite_sequence and survives pruning" {
  for bounded in [false, true] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
    |> ignore
    source.execute("INSERT INTO items VALUES(1,'initial')", []) |> ignore
    source.install_capture(["items"]) |> ignore
    target.initialize_projection(source.snapshot("replica"))
    source.execute("BEGIN", []) |> ignore
    assert_true(
      try {
        source.execute(
          "INSERT OR FAIL INTO items VALUES(2,'kept'),(1,'duplicate')",
          [],
        )
        |> ignore
        false
      } catch {
        _ => true
      },
    )
    source.execute("COMMIT", []) |> ignore
    assert_true(
      source
      .query(
        "SELECT seq FROM main.sqlite_sequence WHERE name='_mooncdc_events'",
        [],
      )
      .is_empty(),
    )
    assert_eq(
      source.query("SELECT sequence FROM main._mooncdc_events", [])[0].values,
      [Integer(1L)],
    )
    assert_eq(source.source_cursor().sequence, 1L)
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
    prune_failed_statement_history(source, bounded, 1)
    source.execute("INSERT INTO items VALUES(3,'after pruning')", []) |> ignore
    assert_eq(source.source_cursor().sequence, 2L)
    assert_eq(
      source.query("SELECT sequence FROM main._mooncdc_events", [])[0].values,
      [Integer(2L)],
    )
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "UPDATE OR FAIL after historical events retains a strictly increasing cursor after pruning" {
  for bounded in [false, true] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
    |> ignore
    source.execute("INSERT INTO items VALUES(1,'one'),(2,'two')", []) |> ignore
    source.install_capture(["items"]) |> ignore
    source.execute("UPDATE items SET value='history one' WHERE id=1", [])
    |> ignore
    source.execute("UPDATE items SET value='history two' WHERE id=2", [])
    |> ignore
    let snapshot = source.snapshot("replica")
    target.initialize_projection(snapshot)
    assert_eq(snapshot.cursor.sequence, 2L)
    source.execute("BEGIN", []) |> ignore
    assert_true(
      try {
        source.execute("UPDATE OR FAIL items SET id=3,value='kept prefix'", [])
        |> ignore
        false
      } catch {
        _ => true
      },
    )
    source.execute("COMMIT", []) |> ignore
    assert_eq(
      source.query(
        "SELECT seq FROM main.sqlite_sequence WHERE name='_mooncdc_events'",
        [],
      )[0].values,
      [Integer(2L)],
    )
    assert_eq(source.source_cursor().sequence, 3L)
    let batch = source.read_batch(snapshot.cursor)
    assert_eq(batch.events.length(), 1)
    assert_eq(batch.end.sequence, 3L)
    assert_eq(batch.high_water, 3L)
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
    prune_failed_statement_history(source, bounded, 3)
    source.execute("INSERT INTO items VALUES(4,'after pruning')", []) |> ignore
    assert_eq(source.source_cursor().sequence, 4L)
    assert_eq(
      source.query("SELECT sequence FROM main._mooncdc_events", [])[0].values,
      [Integer(4L)],
    )
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}
