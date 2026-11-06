///|
test "TEXT parameter adaptation retains SQLite comparison storage classes" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  assert_eq(db.query("SELECT 1 = ?", [Text("1")])[0].values, [Integer(0L)])
  assert_eq(db.query("SELECT ?1 = ?2", [Text("1"), Integer(1L)])[0].values, [
    Integer(0L),
  ])
  assert_eq(db.query("SELECT ?1 IS ?2", [Text("1"), Integer(1L)])[0].values, [
    Integer(0L),
  ])
  assert_eq(
    db.query("SELECT typeof(?1),1 IS ?1,?1 IS 1,?1 BETWEEN 1 AND 1", [Text("1")])[0].values,
    [Text("text"), Integer(0L), Integer(0L), Integer(0L)],
  )
  assert_eq(db.query("SELECT ?1 = ?2", [Text("1"), Text("1")])[0].values, [
    Integer(1L),
  ])
  assert_eq(
    db.query("SELECT ?1=?2,?1 IS ?2,?1 IS NULL", [Text("1"), Null])[0].values,
    [Null, Integer(0L), Integer(0L)],
  )
}

///|
test "TEXT parameters cannot turn a false UPDATE predicate into true" {
  let db = @sqlite.Database::open(":memory:")
  defer db.close()
  db.execute("CREATE TABLE records(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  db.execute("INSERT INTO records VALUES(1,'original')", []) |> ignore
  assert_eq(
    db.execute("UPDATE records SET value='unexpected' WHERE 1=?", [Text("1")]),
    0L,
  )
  assert_eq(db.query("SELECT value FROM records", [])[0].values, [
    Text("original"),
  ])
  // Column affinity still applies normally: this comparison should match id=1.
  assert_eq(
    db.execute("UPDATE records SET value='intended' WHERE id=?", [Text("1")]),
    1L,
  )
  assert_eq(db.query("SELECT value FROM records", [])[0].values, [
    Text("intended"),
  ])
}
