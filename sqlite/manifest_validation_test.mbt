///|
test "corrupt target manifests fail verification status and apply without cursor advancement" {
  let schema : @cdc.Table = {
    name: "items",
    columns: [
      { name: "id", declared_type: "INTEGER", required: true, key_position: 1, },
    ],
  }
  for corrupt in ["[]", @cdc.schemas_to_wire([schema, schema])] {
    let target = @sqlite.Database::open(":memory:")
    defer target.close()
    let snapshot : @cdc.Snapshot = {
      cursor: { source: "source", sequence: 0L, },
      tables: [{ schema, rows: [{ values: [Integer(1L)], }], }],
    }
    target.initialize_projection(snapshot)
    target.execute(
      "UPDATE _mooncdc_projection SET schema_json=? WHERE singleton=1",
      [Text(corrupt)],
    )
    |> ignore
    assert_true(
      try {
        target.verify_projection()
        false
      } catch {
        _ => true
      },
    )
    assert_true(
      try {
        target.projection_status() |> ignore
        false
      } catch {
        _ => true
      },
    )
    let batch : @cdc.Batch = {
      start: snapshot.cursor,
      end: { ..snapshot.cursor, sequence: 1L, },
      high_water: 1L,
      events: [
        {
          sequence: 1L,
          table: "items",
          operation: Insert,
          before: None,
          after: Some({ values: [Integer(2L)], }),
        },
      ],
    }
    batch.validate()
    assert_true(
      try {
        target.apply_batch(batch) |> ignore
        false
      } catch {
        _ => true
      },
    )
    assert_eq(target.projection_cursor(), snapshot.cursor)
    assert_eq(target.query("SELECT id FROM items", [])[0].values, [Integer(1L)])
    assert_true(target.query("SELECT id FROM items WHERE id=2", []).is_empty())
    assert_eq(
      target.query("SELECT schema_json FROM _mooncdc_projection", [])[0].values,
      [Text(corrupt)],
    )
  }
}
