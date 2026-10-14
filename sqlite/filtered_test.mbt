///|
test "durable filter plan cannot change across restart and discarded events advance" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute(
    "CREATE TABLE items(id INTEGER PRIMARY KEY,active INTEGER,name TEXT)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO items VALUES(1,1,'shown'),(2,0,'hidden')", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("filtered")
  let rule = @cdc.TableRule::{
    source: snapshot.tables[0].schema,
    target: "public_items",
    columns: [
      { source: "id", target: "id", },
      { source: "name", target: "name", },
    ],
    filter: Equal("active", Integer(1L)),
  }
  let plan = @cdc.ProjectionPlan::{ rules: [rule], }
  target.initialize_filtered_projection(snapshot, plan)
  source.execute("UPDATE items SET name='hidden update' WHERE id=2", [])
  |> ignore
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 0)
  assert_eq(source.source_cursor(), target.projection_cursor())
  assert_true(
    @sqlite.audit_filtered_projection(source, target, plan).consistent(),
  )
  source.execute("UPDATE items SET active=1 WHERE id=2", []) |> ignore
  let raw = source.read_batch(target.projection_cursor())
  target.apply_filtered_batch(raw, plan) |> ignore
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 0)
  assert_eq(source.consumer_cursor("filtered"), target.projection_cursor())
  let changed = @cdc.ProjectionPlan::{ rules: [{ ..rule, filter: Always, }], }
  assert_true(
    try {
      @sqlite.synchronize_filtered(source, target, "filtered", changed)
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      target.apply_batch(raw) |> ignore
      false
    } catch {
      _ => true
    },
  )
}
