///|
test "ordinary sync rejects filtered target before empty feed or acknowledgement recovery" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,active INTEGER)", [])
  |> ignore
  source.execute("INSERT INTO items VALUES(1,0)", []) |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("filtered")
  let schema = snapshot.tables[0].schema
  // Keep the table and column names unchanged so schema comparison alone cannot
  // distinguish this filtered target from an ordinary projection.
  let plan = @cdc.ProjectionPlan::{
    rules: [
      {
        source: schema,
        target: schema.name,
        columns: schema.columns.map(column => @cdc.ColumnSelection::{
          source: column.name,
          target: column.name,
        }),
        filter: Equal("active", Integer(1L)),
      },
    ],
  }
  target.initialize_filtered_projection(snapshot, plan)
  assert_eq(source.capture_tables(), target.projection_tables())
  assert_true(
    try {
      @sqlite.synchronize(source, target, "filtered") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.consumer_cursor("filtered"), snapshot.cursor)
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 0)

  source.execute("INSERT INTO items VALUES(2,0)", []) |> ignore
  let batch = source.read_batch(snapshot.cursor)
  assert_eq(target.apply_filtered_batch(batch, plan), 0)
  assert_eq(target.projection_cursor(), batch.end)
  assert_eq(source.consumer_cursor("filtered"), batch.start)
  // Simulate exit after filtered target COMMIT but before source acknowledgement.
  // Missing a plan must fail before repairing the source cursor, even though the
  // target already reached the source high-water mark and has no pending events.
  assert_true(
    try {
      @sqlite.synchronize(source, target, "filtered") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.consumer_cursor("filtered"), batch.start)
  assert_eq(target.projection_cursor(), batch.end)
  assert_eq(@sqlite.synchronize_filtered(source, target, "filtered", plan), 0)
  assert_eq(source.consumer_cursor("filtered"), batch.end)
  assert_true(
    @sqlite.audit_filtered_projection(source, target, plan).consistent(),
  )
}
