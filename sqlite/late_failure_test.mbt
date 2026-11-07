///|
fn late_failure_table() -> @cdc.Table {
  {
    name: "items",
    columns: [
      { name: "id", declared_type: "BLOB", required: true, key_position: 1, },
      {
        name: "value",
        declared_type: "BLOB",
        required: false,
        key_position: 0,
      },
    ],
  }
}

///|
test "snapshot SQL uniqueness failure rolls back DDL and permits retry on same connection" {
  let target = @sqlite.Database::open(":memory:")
  defer target.close()
  target.execute("CREATE TABLE unrelated(value TEXT)", []) |> ignore
  target.execute("INSERT INTO unrelated VALUES('keep')", []) |> ignore
  let schema = late_failure_table()
  let snapshot : @cdc.Snapshot = {
    cursor: { source: "source", sequence: 0L, },
    tables: [
      {
        schema,
        rows: [
          { values: [Integer(1L), Text("first")], },
          { values: [Real(1.0), Text("duplicate numeric key")], },
        ],
      },
    ],
  }
  snapshot.validate()
  assert_true(
    try {
      target.initialize_projection(
        @cdc.Snapshot::from_jsonl(snapshot.to_jsonl()),
      )
      false
    } catch {
      _ => true
    },
  )
  assert_false(target.has_object("items"))
  assert_false(target.has_object("_mooncdc_projection"))
  assert_eq(target.query("SELECT value FROM unrelated", [])[0].values, [
    Text("keep"),
  ])
  let valid : @cdc.Snapshot = {
    ..snapshot,
    tables: [
      {
        schema,
        rows: [
          { values: [Integer(1L), Text("first")], },
          { values: [Text("1"), Text("text key")], },
        ],
      },
    ],
  }
  target.initialize_projection(valid)
  assert_eq(target.query("SELECT count(*) FROM items", [])[0].values, [
    Integer(2L),
  ])
  assert_eq(target.projection_cursor(), valid.cursor)
  target.verify_projection()
}

///|
test "late batch validation and before-image errors never leave an applied prefix or cursor" {
  let schema = late_failure_table()
  let original : @cdc.Row = { values: [Integer(1L), Integer(1L)], }
  let after : @cdc.Row = { values: [Integer(1L), Text("updated")], }
  let failures : Array[@cdc.Event] = [
    {
      sequence: 2L,
      table: "missing",
      operation: Insert,
      before: None,
      after: Some({ values: [Integer(3L), Text("missing schema")], }),
    },
    {
      sequence: 2L,
      table: "items",
      operation: Insert,
      before: None,
      after: Some({ values: [Null, Text("null key")], }),
    },
    {
      sequence: 2L,
      table: "items",
      operation: Insert,
      before: None,
      after: Some({ values: [Integer(3L)], }),
    },
    {
      sequence: 2L,
      table: "items",
      operation: Insert,
      before: None,
      after: Some({ values: [Integer(1L), Text("duplicate")], }),
    },
    {
      sequence: 2L,
      table: "items",
      operation: Update,
      before: Some({ values: [Integer(1L), Real(1.0)], }),
      after: Some(after),
    },
    {
      sequence: 2L,
      table: "items",
      operation: Delete,
      before: Some({ values: [Integer(4L), Text("missing row")], }),
      after: None,
    },
  ]
  for failure in failures {
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    let snapshot : @cdc.Snapshot = {
      cursor: { source: "source", sequence: 0L, },
      tables: [{ schema, rows: [original], }],
    }
    target.initialize_projection(snapshot)
    let prefix : @cdc.Event = {
      sequence: 1L,
      table: "items",
      operation: Insert,
      before: None,
      after: Some({ values: [Integer(2L), Text("prefix")], }),
    }
    let batch : @cdc.Batch = {
      start: snapshot.cursor,
      end: { ..snapshot.cursor, sequence: 2L, },
      high_water: 2L,
      events: [prefix, failure],
    }
    let decoded = @cdc.Batch::from_jsonl(batch.to_jsonl())
    assert_true(
      try {
        target.apply_batch(decoded) |> ignore
        false
      } catch {
        _ => true
      },
    )
    assert_eq(target.projection_cursor(), snapshot.cursor)
    assert_eq(target.query(schema.select_sql(), []), [
      { values: original.values, },
    ])
    let repaired : @cdc.Batch = {
      ..batch,
      events: [
        prefix,
        {
          sequence: 2L,
          table: "items",
          operation: Update,
          before: Some(original),
          after: Some(after),
        },
      ],
    }
    assert_eq(target.apply_batch(repaired), 2)
    assert_eq(target.projection_cursor(), repaired.end)
    assert_eq(target.apply_batch(repaired), 0)
    assert_eq(target.query("SELECT count(*) FROM items", [])[0].values, [
      Integer(2L),
    ])
  }
}
