///|
fn assert_real_column_bits(
  source : @sqlite.Database,
  target : @sqlite.Database,
) -> Unit raise {
  let expected = source.query("SELECT id,value FROM reals ORDER BY id", [])
  let actual = target.query("SELECT id,value FROM reals ORDER BY id", [])
  assert_eq(actual.length(), expected.length())
  for index, row in expected {
    assert_eq(actual[index].values[0], row.values[0])
    match (row.values[1], actual[index].values[1]) {
      (Real(left), Real(right)) =>
        assert_eq(left.reinterpret_as_uint64(), right.reinterpret_as_uint64())
      _ => abort("REAL storage class changed during projection")
    }
  }
}

///|
test "snapshot containing 1e300 continues through update delete and replay" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE reals(id INTEGER PRIMARY KEY,value REAL)", [])
  |> ignore
  let original = 0x7e37e43c8800759cUL.reinterpret_as_double()
  source.execute("INSERT INTO reals VALUES(1,?)", [Real(original)]) |> ignore
  source.install_capture(["reals"]) |> ignore
  let snapshot = source.snapshot("real-snapshot")
  // Also cross the external transport boundary instead of passing in-memory rows.
  target.initialize_projection(@cdc.Snapshot::from_jsonl(snapshot.to_jsonl()))
  assert_real_column_bits(source, target)
  source.execute("UPDATE reals SET value=? WHERE id=1", [
    Real(0x7e031cfd3999f7b0UL.reinterpret_as_double()),
  ])
  |> ignore
  let update = source.read_batch(snapshot.cursor)
  assert_eq(target.apply_batch(@cdc.Batch::from_jsonl(update.to_jsonl())), 1)
  assert_real_column_bits(source, target)
  assert_eq(target.apply_batch(update), 0)
  assert_eq(@sqlite.synchronize(source, target, "real-snapshot"), 0)
  source.execute("UPDATE reals SET value=? WHERE id=1", [Real(-original)])
  |> ignore
  assert_eq(@sqlite.synchronize(source, target, "real-snapshot"), 1)
  assert_real_column_bits(source, target)
  source.execute("DELETE FROM reals WHERE id=1", []) |> ignore
  assert_eq(@sqlite.synchronize(source, target, "real-snapshot"), 1)
  assert_real_column_bits(source, target)
}

///|
test "captured REAL extremes preserve bits in JSON and JSONL batches" {
  for format in ["json", "jsonl"] {
    let source = @sqlite.Database::open(":memory:")
    defer source.close()
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    source.execute("CREATE TABLE reals(id INTEGER PRIMARY KEY,value REAL)", [])
    |> ignore
    source.install_capture(["reals"]) |> ignore
    let snapshot = source.snapshot("real-extremes")
    target.initialize_projection(snapshot)
    let patterns : Array[UInt64] = [
      0x0000000000000001UL, 0x8000000000000001UL, 0x000fffffffffffffUL, 0x0010000000000000UL,
      0x3ff0000000000001UL, 0x7e37e43c8800759cUL, 0xfe37e43c8800759cUL, 0x7fefffffffffffffUL,
      0xffefffffffffffffUL,
    ]
    for index, bits in patterns {
      source.execute("INSERT INTO reals VALUES(?,?)", [
        Integer(index.to_int64()),
        Real(bits.reinterpret_as_double()),
      ])
      |> ignore
    }
    let batch = source.read_batch(snapshot.cursor)
    let decoded = if format == "json" {
      @cdc.Batch::from_wire(@cdc.parse_json(batch.to_wire().stringify()))
    } else {
      @cdc.Batch::from_jsonl(batch.to_jsonl())
    }
    assert_eq(target.apply_batch(decoded), patterns.length())
    assert_real_column_bits(source, target)
    source.acknowledge("real-extremes", batch.start, batch.end)
    source.execute("UPDATE reals SET value=-value", []) |> ignore
    assert_eq(
      @sqlite.synchronize(source, target, "real-extremes", batch_limit=2),
      patterns.length(),
    )
    assert_real_column_bits(source, target)
  }
}

///|
test "one ULP external REAL divergence still rolls back the entire batch" {
  let source = @sqlite.Database::open(":memory:")
  defer source.close()
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  source.execute("CREATE TABLE reals(id INTEGER PRIMARY KEY,value REAL)", [])
  |> ignore
  let original = 0x7e37e43c8800759cUL.reinterpret_as_double()
  let changed = 0x7e37e43c8800759bUL.reinterpret_as_double()
  source.execute("INSERT INTO reals VALUES(1,?)", [Real(original)]) |> ignore
  source.install_capture(["reals"]) |> ignore
  let snapshot = source.snapshot("strict-real")
  target.initialize_projection(snapshot)
  target.execute("UPDATE reals SET value=? WHERE id=1", [Real(changed)])
  |> ignore
  source.execute("INSERT INTO reals VALUES(2,?)", [Real(original)]) |> ignore
  source.execute("UPDATE reals SET value=-value WHERE id=1", []) |> ignore
  assert_true(
    try {
      @sqlite.synchronize(source, target, "strict-real") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_eq(target.projection_cursor(), snapshot.cursor)
  assert_eq(source.consumer_cursor("strict-real"), snapshot.cursor)
  let rows = target.query("SELECT value FROM reals", [])
  assert_eq(rows.length(), 1)
  match rows[0].values[0] {
    Real(value) =>
      assert_eq(value.reinterpret_as_uint64(), changed.reinterpret_as_uint64())
    _ => abort("REAL storage class changed")
  }
}
