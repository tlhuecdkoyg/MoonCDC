///|
test "text parameters preserve leading BOM NUL and supplementary Unicode" {
  let database = @sqlite.Database::open(":memory:")
  defer database.close()
  database.execute("CREATE TABLE sentinel(value TEXT)", []) |> ignore
  let value = "\uFEFF'); DROP TABLE sentinel;-- \u0000 😀"
  database.execute("INSERT INTO sentinel VALUES(?)", [Text(value)]) |> ignore
  let rows = database.query("SELECT value,typeof(value) FROM sentinel", [])
  assert_eq(rows[0].values, [Text(value), Text("text")])
  assert_true(database.has_object("sentinel"))
  assert_eq(
    database.query("SELECT ?,typeof(?1)", [Text("\uFEFFpayload\u0000😀")])[0].values,
    [Text("\uFEFFpayload\u0000😀"), Text("text")],
  )
  assert_eq(database.query("SELECT ?,typeof(?1)", [Text("")])[0].values, [
    Text(""),
    Text("text"),
  ])
}

///|
test "text casts retain mixed named numbered anonymous and Tcl parameter indices" {
  let database = @sqlite.Database::open(":memory:")
  defer database.close()
  let first = @cdc.Value::Text("\uFEFFfirst")
  let third = @cdc.Value::Text("\u0000third😀")
  let fifth = @cdc.Value::Text("\uFEFFfifth")
  let sixth = @cdc.Value::Text("\uFEFFsixth")
  let rows = database.query(
    "SELECT :same,?1,?3,:same,?,@other,$deep::name(suffix?x),$deep::name(suffix?x),?2",
    [first, Integer(22L), third, Integer(44L), fifth, sixth],
  )
  assert_eq(rows[0].values, [
    first,
    first,
    third,
    first,
    Integer(44L),
    fifth,
    sixth,
    sixth,
    Integer(22L),
  ])
  // SQLite also accepts '#' names and Tcl suffixes on ':' and '@'.
  assert_eq(
    database.query("SELECT #name,?,:deep::name(x?y),@deep::name(x?y),#name", [
      first, third, fifth, sixth,
    ])[0].values,
    [first, third, fifth, sixth, first],
  )
}

///|
test "parameter lexer skips quoted tokens comments and dollar identifier suffixes" {
  let database = @sqlite.Database::open(":memory:")
  defer database.close()
  let value = @cdc.Value::Text("\uFEFFbound😀")
  let rows = database.query(
    "SELECT 'literal ''?3 :name''',? AS \"double\"\"?99\",?1 AS `back``?77`,?1 AS [square?66],1 AS abc$fake -- :fake ?2\n/* $fake(?) :x */",
    [value],
  )
  assert_eq(rows[0].values, [
    Text("literal '?3 :name'"),
    value,
    value,
    value,
    Integer(1L),
  ])
}
