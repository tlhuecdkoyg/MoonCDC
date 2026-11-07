///|
test "query failure preserves an outer same-name savepoint and its earlier writes" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY)", []) |> ignore
  db.execute("SAVEPOINT _mooncdc_query_scope", []) |> ignore
  db.execute("INSERT INTO items VALUES(99)", []) |> ignore
  assert_true(
    try {
      db.query("INSERT INTO items VALUES(1),(2) RETURNING id", [], max_rows=1)
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(db.query("SELECT id FROM items", [])[0].values, [Integer(99L)])
  db.execute("ROLLBACK TO SAVEPOINT _mooncdc_query_scope", []) |> ignore
  assert_true(db.query("SELECT * FROM items", []).is_empty())
  db.execute("RELEASE SAVEPOINT _mooncdc_query_scope", []) |> ignore
  db.execute("BEGIN", []) |> ignore
  db.execute("ROLLBACK", []) |> ignore
}

///|
test "DML RETURNING row limit failure rolls back and the same connection can retry" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  let sql = "INSERT INTO items VALUES(1,'one'),(2,'two') RETURNING id"
  assert_true(
    try {
      db.query(sql, [], max_rows=1) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(db.query("SELECT * FROM items", []).is_empty())
  assert_eq(db.query(sql, [], max_rows=2).length(), 2)
  db.execute("BEGIN", []) |> ignore
  db.execute("ROLLBACK", []) |> ignore
  assert_eq(db.query("SELECT count(*) FROM items", [])[0].values, [Integer(2L)])
}

///|
test "DML query savepoints preserve caller writes and caller rollback still controls success" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  db.query("BEGIN", []) |> ignore
  db.execute("INSERT INTO items VALUES(99,'caller')", []) |> ignore
  let sql = "INSERT INTO items VALUES(1,'one'),(2,'two') RETURNING id"
  assert_true(
    try {
      db.query(sql, [], max_rows=1) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(db.query("SELECT id FROM items", [])[0].values, [Integer(99L)])
  assert_eq(db.query(sql, [], max_rows=2).length(), 2)
  assert_eq(
    db.query("WITH c(x) AS (VALUES(7)) SELECT x FROM c", [])[0].values,
    [Integer(7L)],
  )
  db.query("ROLLBACK", []) |> ignore
  assert_true(db.query("SELECT * FROM items", []).is_empty())
}

///|
test "query classification scopes commented WITH DML and keeps PRAGMA and read queries compatible" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  let sql = ";; /* prefix */ -- next line\n \uFEFFwItH input(id,value) AS (VALUES(1,'one'),(2,'two')) INSERT INTO items SELECT id,value FROM input RETURNING id"
  assert_true(
    try {
      db.query(sql, [], max_rows=1) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(db.query("SELECT * FROM items", []).is_empty())
  assert_eq(db.query(sql, [], max_rows=2).length(), 2)
  assert_eq(
    db.query("WITH c(x) AS (VALUES(8)) SELECT x FROM c", [])[0].values,
    [Integer(8L)],
  )
  db.query("PRAGMA user_version=17", []) |> ignore
  assert_eq(db.query("PRAGMA user_version", [])[0].values, [Integer(17L)])
  assert_eq(db.query("PRAGMA journal_mode=MEMORY", [])[0].values, [
    Text("memory"),
  ])
  assert_eq(db.query("SELECT ?1,?2", [Integer(1L)])[0].values, [
    Integer(1L),
    Null,
  ])
}

///|
test "OR FAIL DML queries roll back their partial writes without discarding the caller transaction" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  db.execute("INSERT INTO items VALUES(99,'existing')", []) |> ignore
  db.execute("BEGIN", []) |> ignore
  db.execute("INSERT INTO items VALUES(77,'caller')", []) |> ignore
  assert_true(
    try {
      db.query(
        "INSERT OR FAIL INTO items VALUES(1,'prefix'),(99,'duplicate') RETURNING id",
        [],
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(
    db.query("SELECT id FROM items ORDER BY id", []).map(row => row.values[0]),
    [Integer(77L), Integer(99L)],
  )
  db.execute("ROLLBACK", []) |> ignore
  assert_eq(db.query("SELECT id FROM items", [])[0].values, [Integer(99L)])
}

///|
test "explicit OR ROLLBACK retains SQLite transaction semantics and leaves the connection usable" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY)", []) |> ignore
  db.execute("INSERT INTO items VALUES(99)", []) |> ignore
  db.execute("BEGIN", []) |> ignore
  db.execute("INSERT INTO items VALUES(77)", []) |> ignore
  assert_true(
    try {
      db.query("INSERT OR ROLLBACK INTO items VALUES(1),(99) RETURNING id", [])
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(db.query("SELECT id FROM items", [])[0].values, [Integer(99L)])
  db.execute("BEGIN", []) |> ignore
  db.execute("INSERT INTO items VALUES(2)", []) |> ignore
  db.execute("COMMIT", []) |> ignore
  assert_eq(db.query("SELECT count(*) FROM items", [])[0].values, [Integer(2L)])
}
