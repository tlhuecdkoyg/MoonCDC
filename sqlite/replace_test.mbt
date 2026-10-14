///|
test "REPLACE deletes are captured and unsafe writer settings fail closed" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute(
    "CREATE TABLE users(id INTEGER PRIMARY KEY,email TEXT UNIQUE)",
    [],
  )
  |> ignore
  source.execute("INSERT INTO users VALUES(1,'shared')", []) |> ignore
  source.install_capture(["users"]) |> ignore
  target.initialize_projection(source.snapshot("replace"))
  source.execute("INSERT OR REPLACE INTO users VALUES(2,'shared')", [])
  |> ignore
  assert_eq(@sqlite.synchronize(source, target, "replace"), 2)
  assert_true(@sqlite.audit_projection(source, target).consistent())
  source.execute("PRAGMA recursive_triggers=OFF", []) |> ignore
  assert_true(
    try {
      source.execute("INSERT OR REPLACE INTO users VALUES(3,'shared')", [])
      |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(source.query("SELECT id FROM users", [])[0].values, [Integer(2L)])
}
