///|
test "capture committed writes and discard rolled-back changes" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute(
    "CREATE TABLE items(id INTEGER PRIMARY KEY, note TEXT, body BLOB)",
    [],
  )
  |> ignore
  let cursor = db.install_capture(["items"])
  db.verify_capture()
  db.execute("INSERT INTO items VALUES (1,'first',x'00ff')", []) |> ignore
  db.execute("BEGIN", []) |> ignore
  db.execute("INSERT INTO items VALUES (2,'rollback',NULL)", []) |> ignore
  db.execute("ROLLBACK", []) |> ignore
  db.execute("UPDATE items SET note='second' WHERE id=1", []) |> ignore
  db.execute("DELETE FROM items WHERE id=1", []) |> ignore
  let batch = db.read_batch(cursor)
  assert_eq(batch.events.length(), 3)
  assert_eq(batch.events[0].operation, @cdc.Insert)
  assert_eq(batch.events[1].operation, @cdc.Update)
  assert_eq(batch.events[2].operation, @cdc.Delete)
  assert_eq(batch.end.sequence, 3L)
  match batch.events[0].after {
    Some(row) => assert_eq(row.values[2], @cdc.Blob(b"\x00\xff"))
    None => fail("missing inserted image")
  }
}

///|
test "snapshot watermark and consumer retention" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute(
    "CREATE TABLE items(id TEXT PRIMARY KEY NOT NULL, value INTEGER)",
    [],
  )
  |> ignore
  db.execute("INSERT INTO items VALUES ('a',9223372036854775807)", []) |> ignore
  db.install_capture(["items"]) |> ignore
  let snapshot = db.snapshot("report")
  assert_eq(snapshot.row_count(), 1)
  assert_eq(snapshot.cursor.sequence, 0L)
  db.execute("UPDATE items SET value=10 WHERE id='a'", []) |> ignore
  let batch = db.read_batch(snapshot.cursor)
  db.acknowledge("report", batch.start, batch.end)
  db.acknowledge("report", batch.start, batch.end)
  assert_eq(db.prune(), 1L)
  assert_true(
    try {
      db.read_batch(snapshot.cursor) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(db.read_batch(batch.end).events.length(), 0)
}

///|
test "schema and trigger tampering fail closed" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY)", []) |> ignore
  let cursor = db.install_capture(["items"])
  db.execute("DROP TRIGGER _mooncdc_t1_insert", []) |> ignore
  assert_true(
    try {
      db.read_batch(cursor) |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "reject unsupported primary keys and existing nulls" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE bad(id TEXT PRIMARY KEY)", []) |> ignore
  db.execute("INSERT INTO bad VALUES (NULL)", []) |> ignore
  assert_true(
    try {
      db.install_capture(["bad"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_false(db.has_object("_mooncdc_meta"))
  db.execute("CREATE TABLE insensitive(id TEXT PRIMARY KEY COLLATE NOCASE)", [])
  |> ignore
  assert_true(
    try {
      db.install_capture(["insensitive"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
}
