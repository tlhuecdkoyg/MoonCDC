///|
test "diagnose reports each unsupported business trigger alongside missing capture triggers" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  assert_true(@cdc.boolean_field(source.diagnose(), "healthy"))
  source.execute(
    "CREATE TRIGGER \"business audit\" AFTER UPDATE ON items BEGIN SELECT 1; END",
    [],
  )
  |> ignore
  source.execute(
    "CREATE TRIGGER other_listener BEFORE DELETE ON items BEGIN SELECT 2; END",
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
  let unsupported = source.diagnose()
  assert_false(@cdc.boolean_field(unsupported, "healthy"))
  assert_eq(@cdc.array_field(unsupported, "issues").length(), 2)
  for issue in @cdc.array_field(unsupported, "issues") {
    assert_eq(@cdc.string_field(issue, "component"), "unsupported_trigger")
    assert_eq(@cdc.string_field(issue, "table"), "items")
    let name = @cdc.string_field(issue, "name")
    assert_true(name == "business audit" || name == "other_listener")
  }
  source.execute("DROP TRIGGER _mooncdc_t1_insert", []) |> ignore
  let combined = source.diagnose()
  assert_false(@cdc.boolean_field(combined, "healthy"))
  assert_eq(@cdc.array_field(combined, "issues").length(), 3)
  let mut missing = false
  for issue in @cdc.array_field(combined, "issues") {
    if @cdc.string_field(issue, "component") == "trigger" {
      assert_eq(@cdc.string_field(issue, "name"), "_mooncdc_t1_insert")
      missing = true
    }
  }
  assert_true(missing)
  // Diagnostic collection must not silently repair either kind of trigger issue.
  assert_true(source.has_object("business audit"))
  assert_true(source.has_object("other_listener"))
  assert_false(source.has_object("_mooncdc_t1_insert"))
}
