///|
test "ordinary tables can contain virtual table words in defaults and identifiers" {
  for
    (name, definition, column) in [
      (
        "items", "CREATE TABLE items(id INTEGER PRIMARY KEY,note TEXT DEFAULT 'VIRTUAL TABLE')",
        "note",
      ),
      (
        "items", "CREATE TABLE items(id INTEGER PRIMARY KEY,\"virtual table\" TEXT)",
        "virtual table",
      ),
      (
        "virtual table", "CREATE TABLE \"virtual table\"(id INTEGER PRIMARY KEY,note TEXT)",
        "note",
      ),
    ] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute(definition, []) |> ignore
    let table = @cdc.quote_identifier(name)
    let selected = @cdc.quote_identifier(column)
    source.execute("INSERT INTO " + table + "(id) VALUES(1)", []) |> ignore
    source.install_capture([name]) |> ignore
    let snapshot = source.snapshot("replica")
    assert_eq(snapshot.tables[0].schema.name, name)
    assert_eq(snapshot.row_count(), 1)
    target.initialize_projection(snapshot)
    source.execute("UPDATE " + table + " SET " + selected + "=? WHERE id=1", [
      Text("ordinary table update"),
    ])
    |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "virtual and shadow tables are rejected when an FTS module is compiled" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let modules = source.query("SELECT name FROM pragma_module_list", [])
  let mut sqlite_module : String? = None
  for row in modules {
    if row.values[0] is Text("fts5") {
      sqlite_module = Some("fts5")
      break
    }
    if row.values[0] is Text("fts4") {
      sqlite_module = Some("fts4")
    }
  }
  if sqlite_module is Some(sqlite_module) {
    source.execute(
      "CREATE VIRTUAL TABLE search USING " + sqlite_module + "(content)",
      [],
    )
    |> ignore
    assert_true(
      try {
        source.inspect_table("search") |> ignore
        false
      } catch {
        _ => true
      },
    )
    let shadow = source.query(
      "SELECT name FROM pragma_table_list WHERE schema='main' AND type='shadow' ORDER BY name",
      [],
    )
    assert_false(shadow.is_empty())
    for row in shadow {
      if row.values[0] is Text(name) {
        assert_true(
          try {
            source.inspect_table(name) |> ignore
            false
          } catch {
            _ => true
          },
        )
      }
    }
    assert_false(source.has_object("_mooncdc_meta"))
  }
}
