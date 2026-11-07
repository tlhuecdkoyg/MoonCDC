///|
test "ordinary sqlite prefix names remain listed while reserved metadata is case insensitive" {
  let database = @sqlite.Database::open(":memory:")
  defer database.close()
  for name in ["business", "sqlite", "sqliteX", "sqlitexyz", "_MOONCDC_STALE"] {
    database.execute(
      "CREATE TABLE " + @cdc.quote_identifier(name) + "(id INTEGER PRIMARY KEY)",
      [],
    )
    |> ignore
  }
  let names = database.list_tables()
  assert_eq(names.length(), 4)
  for name in ["business", "sqlite", "sqliteX", "sqlitexyz"] {
    assert_true(names.contains(name))
  }
  let plan = database.plan_capture(["business"])
  assert_true(@cdc.boolean_field(plan, "metadata_already_exists"))
  assert_false(@cdc.boolean_field(plan, "eligible"))
  assert_true(
    try {
      database.install_capture(["business"]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_false(database.has_object("_mooncdc_meta"))
  assert_true(database.has_object("_MOONCDC_STALE"))
}

///|
test "a legal sqliteX table completes capture and projection" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE sqliteX(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(source.list_tables()) |> ignore
  let snapshot = source.snapshot("replica")
  target.execute("CREATE VIEW _MOONCDC_STALE AS SELECT 1", []) |> ignore
  assert_true(
    try {
      target.initialize_projection(snapshot)
      false
    } catch {
      _ => true
    },
  )
  assert_false(target.has_object("_mooncdc_projection"))
  assert_false(target.has_object("sqliteX"))
  assert_true(target.has_object("_MOONCDC_STALE"))
  target.execute("DROP VIEW _MOONCDC_STALE", []) |> ignore
  target.initialize_projection(snapshot)
  source.execute("INSERT INTO sqliteX VALUES(1,'supported')", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}
