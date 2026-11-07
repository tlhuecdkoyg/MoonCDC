///|
test "self ON DELETE SET DEFAULT cannot relocate another row into the pending deleted key" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute(
    "CREATE TABLE nodes(id INTEGER PRIMARY KEY DEFAULT 1 REFERENCES nodes(refkey) ON DELETE SET DEFAULT,refkey INTEGER UNIQUE)",
    [],
  )
  |> ignore
  source.execute("PRAGMA foreign_keys=OFF", []) |> ignore
  source.execute("INSERT INTO nodes VALUES(1,2),(2,1)", []) |> ignore
  source.execute("PRAGMA foreign_keys=ON", []) |> ignore
  let plan = source.plan_capture(["nodes"])
  assert_false(@cdc.boolean_field(plan, "eligible"))
  assert_true(
    @cdc.string_field(@cdc.array_field(plan, "tables")[0], "error").contains(
      "ON DELETE action path",
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
}

///|
test "mixed DELETE UPDATE paths include uncaptured intermediate tables" {
  for captured in [["A"], ["A", "B"], ["B"]] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    source.execute("PRAGMA foreign_keys=OFF", []) |> ignore
    source.execute(
      "CREATE TABLE A(id INTEGER PRIMARY KEY DEFAULT 1 REFERENCES B(refkey) ON DELETE SET DEFAULT)",
      [],
    )
    |> ignore
    source.execute(
      "CREATE TABLE B(id INTEGER PRIMARY KEY,a INTEGER REFERENCES A(id) ON UPDATE CASCADE ON DELETE CASCADE,refkey INTEGER UNIQUE)",
      [],
    )
    |> ignore
    source.execute("INSERT INTO A VALUES(1),(2)", []) |> ignore
    source.execute("INSERT INTO B VALUES(1,1,2),(2,2,1)", []) |> ignore
    source.execute("PRAGMA foreign_keys=ON", []) |> ignore
    let plan = source.plan_capture(captured)
    if captured == ["B"] {
      // The path returns to B only through its non-key column 'a'. Capturing B
      // alone remains replayable even though the uncaptured A key is relocated.
      assert_true(@cdc.boolean_field(plan, "eligible"))
      source.install_capture(captured) |> ignore
      let target = @sqlite.Database::open(":memory:")
      defer target.close()
      target.initialize_projection(source.snapshot("replica"))
      source.execute("DELETE FROM A WHERE id=1", []) |> ignore
      assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
      assert_true(@sqlite.audit_projection(source, target).consistent())
    } else {
      assert_false(@cdc.boolean_field(plan, "eligible"))
      assert_true(
        @cdc.string_field(@cdc.array_field(plan, "tables")[0], "error").contains(
          "ON DELETE action path",
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
}

///|
test "nonkey self deletion actions and pure deletion cascades remain replayable" {
  for action in ["SET NULL", "SET DEFAULT", "CASCADE"] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute(
      "CREATE TABLE nodes(id INTEGER PRIMARY KEY,parent INTEGER DEFAULT 0 REFERENCES nodes(id) ON DELETE " +
      action +
      ")",
      [],
    )
    |> ignore
    source.execute("INSERT INTO nodes VALUES(0,0),(1,0),(2,1)", []) |> ignore
    assert_true(@cdc.boolean_field(source.plan_capture(["nodes"]), "eligible"))
    source.install_capture(["nodes"]) |> ignore
    target.initialize_projection(source.snapshot("replica"))
    source.execute("DELETE FROM nodes WHERE id=1", []) |> ignore
    assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
    assert_true(@sqlite.audit_projection(source, target).consistent())
  }
}

///|
test "acyclic composite foreign keys may move child keys after a parent deletion" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute(
    "CREATE TABLE parents(tenant TEXT,code INTEGER,PRIMARY KEY(tenant,code)) WITHOUT ROWID",
    [],
  )
  |> ignore
  source.execute(
    "CREATE TABLE children(tenant TEXT DEFAULT 'fallback',code INTEGER DEFAULT 0,line INTEGER,PRIMARY KEY(tenant,code,line),FOREIGN KEY(tenant,code) REFERENCES parents(tenant,code) ON UPDATE CASCADE ON DELETE SET DEFAULT) WITHOUT ROWID",
    [],
  )
  |> ignore
  source.execute("INSERT INTO parents VALUES('fallback',0),('main',1)", [])
  |> ignore
  source.execute("INSERT INTO children VALUES('main',1,7)", []) |> ignore
  assert_true(
    @cdc.boolean_field(source.plan_capture(["parents", "children"]), "eligible"),
  )
  source.install_capture(["parents", "children"]) |> ignore
  target.initialize_projection(source.snapshot("replica"))
  source.execute("DELETE FROM parents WHERE tenant='main'", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replica"), 2)
  assert_eq(target.query("SELECT * FROM children", [])[0].values, [
    Text("fallback"),
    Integer(0L),
    Integer(7L),
  ])
  assert_true(@sqlite.audit_projection(source, target).consistent())
}

///|
test "creating a missing table can introduce a forbidden DELETE key return path" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute(
    "CREATE TABLE A(id INTEGER PRIMARY KEY DEFAULT 1 REFERENCES B(refkey) ON DELETE SET DEFAULT)",
    [],
  )
  |> ignore
  source.install_capture(["A"]) |> ignore
  let snapshot = source.snapshot("replica")
  source.execute(
    "CREATE TABLE B(id INTEGER PRIMARY KEY,a INTEGER REFERENCES A(id) ON DELETE CASCADE,refkey INTEGER UNIQUE)",
    [],
  )
  |> ignore
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
        @cdc.string_field(issue, "error").contains("ON DELETE action path"),
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
