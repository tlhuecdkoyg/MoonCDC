///|
async test "query rolls back an owned transaction when COMMIT is busy and can retry" {
  let directory = @fs.tmpdir(prefix="mooncdc-query-commit-busy")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/database.sqlite3"
  let writer = @sqlite.Database::open(path)
  defer writer.close()
  writer.execute("PRAGMA journal_mode=DELETE", []) |> ignore
  writer.execute("CREATE TABLE items(id INTEGER PRIMARY KEY)", []) |> ignore
  writer.execute("PRAGMA busy_timeout=1", []) |> ignore
  let reader = @sqlite.Database::open(path)
  defer reader.close()
  reader.execute("BEGIN", []) |> ignore
  defer (try reader.execute("ROLLBACK", []) |> ignore catch {
    _ => ()
  })
  // Finishing this SELECT does not release the explicit reader transaction's
  // shared lock. The writer can change rows but cannot acquire COMMIT's lock.
  assert_eq(reader.query("SELECT count(*) FROM items", [])[0].values, [
    Integer(0L),
  ])
  let busy = try {
    writer.query("INSERT INTO items VALUES(1) RETURNING id", [], max_rows=10)
    |> ignore
    false
  } catch {
    @sqlite3.SqliteError(code=Busy, ..) => true
    error => raise error
  }
  assert_true(busy)
  // A leftover owned transaction would make BEGIN fail. It must also contain
  // no half-applied data even though RETURNING produced a row before COMMIT.
  writer.execute("BEGIN", []) |> ignore
  assert_eq(writer.query("SELECT count(*) FROM items", [])[0].values, [
    Integer(0L),
  ])
  writer.execute("ROLLBACK", []) |> ignore
  reader.execute("ROLLBACK", []) |> ignore
  let result = writer.query(
    "INSERT INTO items VALUES(1) RETURNING id",
    [],
    max_rows=10,
  )
  assert_eq(result.length(), 1)
  assert_eq(result[0].values, [Integer(1L)])
  assert_eq(reader.query("SELECT id FROM items", [])[0].values, [Integer(1L)])
}
