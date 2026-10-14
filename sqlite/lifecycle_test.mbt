///|
test "preview rolls back, fork pins retention and uninstall requires drained state" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  let identity = source.install_capture(["items"])
  let snapshot = source.snapshot("replica")
  target.initialize_projection(snapshot)
  source.fork_consumer("replica", "slow") |> ignore
  source.execute("INSERT INTO items VALUES(1,'one'),(2,'two'),(3,'three')", [])
  |> ignore
  let batch = source.read_batch(snapshot.cursor)
  let preview = target.preview_batch(batch)
  assert_eq(@cdc.boolean_field(preview, "applicable"), true)
  assert_eq(target.projection_cursor(), snapshot.cursor)
  assert_true(target.query("SELECT * FROM items", []).is_empty())
  @sqlite.synchronize(source, target, "replica") |> ignore
  assert_eq(@cdc.string_field(source.retention_plan(), "safe_through"), "0")
  assert_eq(source.prune_bounded(1), 0L)
  source.drop_consumer("slow")
  assert_eq(source.prune_bounded(1), 1L)
  assert_true(
    try {
      source.register_checkpoint("stale", snapshot.cursor)
      false
    } catch {
      _ => true
    },
  )
  source.register_checkpoint("restored", target.projection_cursor())
  assert_eq(source.prune_bounded(2), 2L)
  assert_true(
    try {
      source.uninstall_capture(identity.source)
      false
    } catch {
      _ => true
    },
  )
  source.drop_consumer("replica")
  source.drop_consumer("restored")
  assert_true(
    try {
      source.uninstall_capture("wrong")
      false
    } catch {
      _ => true
    },
  )
  source.uninstall_capture(identity.source)
  assert_eq(source.query("SELECT * FROM items", []).length(), 3)
  assert_false(source.has_object("_mooncdc_meta"))
}

///|
test "diagnostics reports multiple broken triggers without repairing source" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  assert_true(
    @cdc.boolean_field(source.diagnose(check_storage=true), "healthy"),
  )
  source.execute("DROP TRIGGER _mooncdc_t1_insert", []) |> ignore
  source.execute("DROP TRIGGER _mooncdc_t1_update", []) |> ignore
  let report = source.diagnose()
  assert_false(@cdc.boolean_field(report, "healthy"))
  assert_eq(@cdc.array_field(report, "issues").length(), 2)
  assert_false(source.has_object("_mooncdc_t1_insert"))
}

///|
test "adjacent compaction preserves target state and final cursor" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE items(id INTEGER PRIMARY KEY,value TEXT)", [])
  |> ignore
  source.install_capture(["items"]) |> ignore
  let snapshot = source.snapshot("compact")
  target.initialize_projection(snapshot)
  source.execute("INSERT INTO items VALUES(1,'one')", []) |> ignore
  source.execute("UPDATE items SET value='two' WHERE id=1", []) |> ignore
  source.execute("DELETE FROM items WHERE id=1", []) |> ignore
  source.execute("INSERT INTO items VALUES(2,'old')", []) |> ignore
  source.execute("UPDATE items SET value='new' WHERE id=2", []) |> ignore
  let raw = source.read_batch(snapshot.cursor)
  let compact = raw.compact_adjacent(snapshot.schemas())
  assert_eq(compact.events.length(), 1)
  assert_eq(target.apply_batch(compact), 1)
  assert_true(@sqlite.audit_projection(source, target).consistent())
  let summary = raw.summarize(snapshot.schemas())
  assert_eq(@cdc.array_field(summary, "tables").length(), 1)
}
