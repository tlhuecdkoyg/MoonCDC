///|
test "unrelated TEMP AUTOINCREMENT tables cannot reset the source watermark" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  source.execute("INSERT INTO items VALUES(1,'before')", []) |> ignore
  let before = source.source_cursor()
  assert_eq(before.sequence, 1L)
  source.execute(
    "CREATE TEMP TABLE staging(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO staging(value) VALUES('unrelated')", []) |> ignore
  // SQLite now has both main.sqlite_sequence and temp.sqlite_sequence.
  assert_eq(source.source_cursor(), before)
  let snapshot = source.snapshot("replica")
  assert_eq(snapshot.cursor, before)
  target.initialize_projection(snapshot)
  target.execute(
    "CREATE TEMP TABLE staging(id INTEGER PRIMARY KEY AUTOINCREMENT)",
    [],
  )
  |> ignore
  source.execute("UPDATE items SET value='after'", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_eq(source.consumer_cursor("replica").sequence, 2L)
  assert_true(@sqlite.audit_projection(source, target).consistent())
  assert_eq(source.prune(), 2L)
  assert_eq(source.source_cursor().sequence, 2L)
  source.execute("INSERT INTO items VALUES(2,'after prune')", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_eq(source.source_cursor().sequence, 3L)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}
