///|
test "projection key change, replay and lagging acknowledgement recovery" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE records(id INTEGER PRIMARY KEY, value)", [])
  |> ignore
  source.execute("INSERT INTO records VALUES (1,'old')", []) |> ignore
  source.install_capture(["records"]) |> ignore
  let snapshot = source.snapshot("report")
  target.initialize_projection(snapshot)
  source.execute(
    "UPDATE records SET id=2,value=0.12345678901234567 WHERE id=1",
    [],
  )
  |> ignore
  let batch = source.read_batch(snapshot.cursor)
  assert_eq(target.apply_batch(batch), 1)
  assert_eq(target.apply_batch(batch), 0)
  assert_eq(@sqlite.synchronize(source, target, "report"), 0)
  assert_eq(source.consumer_cursor("report"), target.projection_cursor())
  assert_eq(
    source.query("SELECT * FROM records", []),
    target.query("SELECT * FROM records", []),
  )
  source.execute("DELETE FROM records", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "report"), 1)
  assert_true(target.query("SELECT * FROM records", []).is_empty())
}

///|
test "divergence rolls back earlier events and preserves cursor" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.execute("INSERT INTO items VALUES (1,'original')", []) |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("report")
  target.initialize_projection(snapshot)
  target.execute("UPDATE items SET value='unexpected' WHERE id=1", []) |> ignore
  source.execute("INSERT INTO items VALUES (2,'must roll back')", []) |> ignore
  source.execute("UPDATE items SET value='new' WHERE id=1", []) |> ignore
  assert_true(
    try {
      @sqlite.synchronize(source, target, "report") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(target.projection_cursor(), snapshot.cursor)
  assert_eq(target.query("SELECT * FROM items", []).length(), 1)
}
