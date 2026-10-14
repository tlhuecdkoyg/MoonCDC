///|
test "filtered projection handles membership transitions and empty intervals" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute(
    "CREATE TABLE items(id INTEGER PRIMARY KEY,active INTEGER,name TEXT)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO items VALUES(1,0,'hidden'),(2,1,'visible')", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("filtered")
  let plan = @cdc.ProjectionPlan::{
    rules: [
      {
        source: snapshot.tables[0].schema,
        target: "public_items",
        columns: [
          { source: "id", target: "id", },
          { source: "name", target: "label", },
        ],
        filter: Equal("active", Integer(1L)),
      },
    ],
  }
  assert_eq(@cdc.ProjectionPlan::from_wire(plan.to_wire()), plan)
  target.initialize_projection(plan.project_snapshot(snapshot))
  source.execute("UPDATE items SET active=1 WHERE id=1", []) |> ignore
  source.execute("UPDATE items SET active=0 WHERE id=2", []) |> ignore
  let raw = source.read_batch(snapshot.cursor)
  let batch = plan.project_batch(raw)
  assert_eq(batch.events[0].operation, @cdc.Insert)
  assert_eq(batch.events[1].operation, @cdc.Delete)
  assert_eq(target.apply_batch(batch), 2)
  assert_eq(target.query("SELECT * FROM public_items", [])[0].values, [
    Integer(1L),
    Text("hidden"),
  ])
  source.acknowledge("filtered", raw.start, raw.end)
  source.execute("UPDATE items SET name='still hidden' WHERE id=2", [])
  |> ignore
  let empty = plan.project_batch(source.read_batch(raw.end))
  assert_true(empty.events.is_empty())
  assert_eq(target.apply_batch(@cdc.Batch::from_jsonl(empty.to_jsonl())), 0)
  assert_eq(target.projection_cursor(), empty.end)
}

///|
test "content audit finds external edits and journal audit rejects missing events" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("INSERT INTO items VALUES(1,'one'),(2,'two')", []) |> ignore
  source.install_capture(["items"]) |> ignore
  target.initialize_projection(source.snapshot("audit"))
  assert_true(@sqlite.audit_projection(source, target).consistent())
  target.execute("UPDATE items SET value='changed' WHERE id=1", []) |> ignore
  target.execute("DELETE FROM items WHERE id=2", []) |> ignore
  target.execute("INSERT INTO items VALUES(3,'extra')", []) |> ignore
  let report = @sqlite.audit_projection(source, target, sample_limit=2)
  assert_false(report.consistent())
  assert_eq(report.tables[0].changed, 1)
  assert_eq(report.tables[0].missing, 1)
  assert_eq(report.tables[0].unexpected, 1)
  assert_eq(report.tables[0].samples.length(), 2)
  source.execute("UPDATE items SET value='new'", []) |> ignore
  source.audit_journal() |> ignore
  source.execute("DELETE FROM _mooncdc_events WHERE sequence=1", []) |> ignore
  assert_true(
    try {
      source.audit_journal() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @sqlite.audit_projection(source, target) |> ignore
      false
    } catch {
      _ => true
    },
  )
}
