///|
test "self-referencing mutating ON UPDATE actions are rejected before installing metadata" {
  for action in ["CASCADE", "SET NULL", "SET DEFAULT"] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    source.execute(
      "CREATE TABLE nodes(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES nodes(id) ON UPDATE " +
      action +
      ")",
      [],
    )
    |> ignore
    source.execute("INSERT INTO nodes VALUES(1,1)", []) |> ignore
    let plan = source.plan_capture(["nodes"])
    assert_false(@cdc.boolean_field(plan, "eligible"))
    assert_true(
      @cdc.string_field(@cdc.array_field(plan, "tables")[0], "error").contains(
        "ON UPDATE action cycle",
      ),
    )
    assert_true(
      try {
        source.install_capture(["nodes"]) |> ignore
        false
      } catch {
        _ => true
      },
    )
    assert_false(source.has_object("_mooncdc_meta"))
    assert_eq(source.query("SELECT * FROM nodes", [])[0].values, [
      Integer(1L),
      Integer(1L),
    ])
  }
}

///|
test "ON UPDATE action cycles include uncaptured intermediate tables" {
  for captured in [["A"], ["B"], ["A", "B"]] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    source.execute("PRAGMA foreign_keys=OFF", []) |> ignore
    source.execute(
      "CREATE TABLE A(id INTEGER PRIMARY KEY,b INTEGER REFERENCES B(id) ON UPDATE CASCADE)",
      [],
    )
    |> ignore
    source.execute(
      "CREATE TABLE B(id INTEGER PRIMARY KEY REFERENCES A(id) ON UPDATE CASCADE)",
      [],
    )
    |> ignore
    source.execute("INSERT INTO A VALUES(1,1)", []) |> ignore
    source.execute("INSERT INTO B VALUES(1)", []) |> ignore
    source.execute("PRAGMA foreign_keys=ON", []) |> ignore
    let plan = source.plan_capture(captured)
    assert_false(@cdc.boolean_field(plan, "eligible"))
    assert_true(
      @cdc.string_field(@cdc.array_field(plan, "tables")[0], "error").contains(
        "ON UPDATE action cycle",
      ),
    )
    assert_true(
      try {
        source.install_capture(captured) |> ignore
        false
      } catch {
        _ => true
      },
    )
    assert_false(source.has_object("_mooncdc_meta"))
  }
}

///|
test "NO ACTION self-reference and delete-only cascades remain supported" {
  for clause in ["ON UPDATE NO ACTION", "ON DELETE CASCADE"] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute(
      "CREATE TABLE nodes(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES nodes(id) " +
      clause +
      ")",
      [],
    )
    |> ignore
    source.execute("INSERT INTO nodes VALUES(1,1)", []) |> ignore
    assert_true(@cdc.boolean_field(source.plan_capture(["nodes"]), "eligible"))
    source.install_capture(["nodes"]) |> ignore
    target.initialize_projection(source.snapshot("replica"))
    source.execute("UPDATE nodes SET id=2,parent=2 WHERE id=1", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
    source.execute("DELETE FROM nodes WHERE id=2", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 1)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "acyclic parent child ON UPDATE and ON DELETE cascades synchronize" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE parents(id INTEGER PRIMARY KEY)", []) |> ignore
  source.execute(
    "CREATE TABLE children(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES parents(id) ON UPDATE CASCADE ON DELETE CASCADE)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO parents VALUES(1)", []) |> ignore
  source.execute("INSERT INTO children VALUES(10,1)", []) |> ignore
  source.install_capture(["parents", "children"]) |> ignore
  target.initialize_projection(source.snapshot("replica"))
  source.execute("UPDATE parents SET id=2 WHERE id=1", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
  assert_true(@sqlite.audit_projection(source, target).consistent())
  source.execute("DELETE FROM parents WHERE id=2", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "DDL in an uncaptured table can make an existing capture action graph unsafe" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE B(id INTEGER PRIMARY KEY)", []) |> ignore
  source.execute(
    "CREATE TABLE A(id INTEGER PRIMARY KEY REFERENCES B(id) ON UPDATE CASCADE)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO B VALUES(1)", []) |> ignore
  source.execute("INSERT INTO A VALUES(1)", []) |> ignore
  source.install_capture(["A"]) |> ignore
  let snapshot = source.snapshot("replica")
  source.execute("PRAGMA foreign_keys=OFF", []) |> ignore
  source.execute("DROP TABLE B", []) |> ignore
  source.execute(
    "CREATE TABLE B(id INTEGER PRIMARY KEY REFERENCES A(id) ON UPDATE CASCADE)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO B VALUES(1)", []) |> ignore
  source.execute("PRAGMA foreign_keys=ON", []) |> ignore
  assert_true(
    try {
      source.verify_capture()
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.read_batch(snapshot.cursor) |> ignore
      false
    } catch {
      _ => true
    },
  )
  let report = source.diagnose()
  assert_false(@cdc.boolean_field(report, "healthy"))
  let mut found = false
  for issue in @cdc.array_field(report, "issues") {
    if @cdc.string_field(issue, "component") == "foreign_key_actions" {
      assert_true(
        @cdc.string_field(issue, "error").contains("ON UPDATE action cycle"),
      )
      found = true
    }
  }
  assert_true(found)
  assert_eq(source.consumer_cursor("replica"), snapshot.cursor)
}

///|
test "creating an initially missing uncaptured parent rejects an existing capture cycle" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute(
    "CREATE TABLE A(id INTEGER PRIMARY KEY,b INTEGER REFERENCES B(id) ON UPDATE CASCADE)",
    [],
  )
  |> ignore
  source.install_capture(["A"]) |> ignore
  let snapshot = source.snapshot("replica")
  let definition = source.query(
    "SELECT sql FROM main.sqlite_schema WHERE name='A'",
    [],
  )
  source.execute(
    "CREATE TABLE B(id INTEGER PRIMARY KEY REFERENCES A(id) ON UPDATE CASCADE)",
    [],
  )
  |> ignore
  assert_eq(
    source.query("SELECT sql FROM main.sqlite_schema WHERE name='A'", []),
    definition,
  )
  assert_true(
    try {
      source.verify_capture()
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.read_batch(snapshot.cursor) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      source.snapshot("must-not-register") |> ignore
      false
    } catch {
      _ => true
    },
  )
  let report = source.diagnose()
  assert_false(@cdc.boolean_field(report, "healthy"))
  let mut found = false
  for issue in @cdc.array_field(report, "issues") {
    if @cdc.string_field(issue, "component") == "foreign_key_actions" {
      assert_true(
        @cdc.string_field(issue, "error").contains("ON UPDATE action cycle"),
      )
      found = true
    }
  }
  assert_true(found)
  assert_eq(source.source_cursor(), snapshot.cursor)
  assert_eq(source.consumer_cursor("replica"), snapshot.cursor)
  assert_eq(
    source.query("SELECT count(*) FROM main._mooncdc_events", [])[0].values,
    [Integer(0L)],
  )
  assert_eq(
    source.query("SELECT name FROM main._mooncdc_consumers", [])[0].values,
    [Text("replica")],
  )
}
