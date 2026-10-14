///|
test "lossless values and signed 64-bit boundaries" {
  let values : Array[@MoonCDC.Value] = [
    Null,
    Integer(-9223372036854775807L - 1L),
    Integer(9223372036854775807L),
    Real(0.125),
    Text("quoted \" and \u0000 and 中文"),
    Blob(b"\x00\xff"),
  ]
  for value in values {
    assert_eq(
      @MoonCDC.Value::from_wire(
        @MoonCDC.parse_json(value.to_wire().stringify()),
      ),
      value,
    )
  }
  assert_true(
    try {
      @MoonCDC.parse_integer("9223372036854775808") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @MoonCDC.parse_integer("-9223372036854775809") |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @MoonCDC.decode_hex("abc") |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "batch rejects reorder and malformed images" {
  let row : @MoonCDC.Row = { values: [Integer(1L)], }
  let event : @MoonCDC.Event = {
    sequence: 1L,
    table: "orders",
    operation: Insert,
    before: None,
    after: Some(row),
  }
  let batch : @MoonCDC.Batch = {
    start: { source: "example", sequence: 0L, },
    end: { source: "example", sequence: 1L, },
    high_water: 1L,
    events: [event],
  }
  assert_eq(@MoonCDC.Batch::from_wire(batch.to_wire()), batch)
  assert_true(
    try {
      { ..batch, events: [event, event], }.validate() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      { ..event, before: Some(row), }.validate() |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "SQL quotes identifiers separately from bound values" {
  let table : @MoonCDC.Table = {
    name: "weird\"table",
    columns: [
      { name: "key", declared_type: "TEXT", required: true, key_position: 1, },
      {
        name: "payload",
        declared_type: "BLOB",
        required: false,
        key_position: 0,
      },
    ],
  }
  let row : @MoonCDC.Row = {
    values: [Text("';DROP TABLE users;--"), Blob(b"abc")],
  }
  let statement = table.insert_statement(row)
  assert_true(statement.sql.contains("\"weird\"\"table\""))
  assert_false(statement.sql.contains("DROP TABLE"))
  assert_eq(statement.parameters, row.values)
  assert_eq(@MoonCDC.Table::from_wire(table.to_wire()), table)
  assert_true(table.trigger_sql(1, Insert).contains("AFTER INSERT"))
}
