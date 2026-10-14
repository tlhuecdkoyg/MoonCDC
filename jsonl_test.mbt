///|
test "framed JSONL survives arbitrary chunks and rejects truncation" {
  let batch : @MoonCDC.Batch = {
    start: { source: "source", sequence: 0L, },
    end: { source: "source", sequence: 1L, },
    high_water: 1L,
    events: [
      {
        sequence: 1L,
        table: "t",
        operation: Insert,
        before: None,
        after: Some({ values: [Integer(1L), Text("\n中文")], }),
      },
    ],
  }
  let wire = batch.to_jsonl()
  for chunk_size in [1, 2, 7, 64] {
    let decoder = @MoonCDC.BatchDecoder::new()
    let mut offset = 0
    while offset < wire.length() {
      let end = (offset + chunk_size).min(wire.length())
      decoder.feed(wire[offset:end].to_owned())
      offset = end
    }
    assert_eq(decoder.finish(), batch)
  }
  let truncated = wire.split("\n").to_array()[0].to_owned() + "\n"
  assert_true(
    try {
      @MoonCDC.Batch::from_jsonl(truncated) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      @MoonCDC.Batch::from_jsonl(wire + "{}\n") |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "snapshot JSONL requires a complete framed set" {
  let snapshot : @MoonCDC.Snapshot = {
    cursor: { source: "source", sequence: 2L, },
    tables: [
      {
        schema: {
          name: "t",
          columns: [
            {
              name: "id",
              declared_type: "INTEGER",
              required: true,
              key_position: 1,
            },
          ],
        },
        rows: [{ values: [Integer(1L)], }],
      },
    ],
  }
  assert_eq(@MoonCDC.Snapshot::from_jsonl(snapshot.to_jsonl()), snapshot)
  assert_eq(@MoonCDC.Snapshot::from_wire(snapshot.to_wire()), snapshot)
}
