///|
#cfg(target="native")
test "default JSONL line budget includes the envelope around a maximum source event" {
  let template : @MoonCDC.Event = {
    sequence: 1L,
    table: "items",
    operation: Insert,
    before: None,
    after: Some({ values: [Integer(1L), Blob(b"")], }),
  }
  let event_budget = 16777216
  let overhead = template.to_wire().stringify().length()
  let payload_size = (event_budget - overhead) / 2
  let payload = Bytes::from_iter(Array::make(payload_size, b'a').iter())
  let event : @MoonCDC.Event = {
    ..template,
    after: Some({ values: [Integer(1L), Blob(payload)], }),
  }
  let event_units = event.to_wire().stringify().length()
  assert_true(event_units <= event_budget && event_budget - event_units <= 1)
  let batch : @MoonCDC.Batch = {
    start: { source: "source", sequence: 0L, },
    end: { source: "source", sequence: 1L, },
    high_water: 1L,
    events: [event],
  }
  let wire = batch.to_jsonl()
  let mut longest = 0
  for line in wire.split("\n") {
    longest = longest.max(line.length())
  }
  assert_true(longest > event_budget)
  let decoded = @MoonCDC.Batch::from_jsonl(wire)
  // Keep any failure output bounded rather than printing an 8 MiB BLOB.
  assert_true(decoded == batch)
  let strict = @MoonCDC.BatchDecoder::new(max_line_units=event_budget)
  assert_true(
    try {
      strict.feed(wire)
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      strict.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "implicit framing margin preserves older total-only configurations" {
  let batch : @MoonCDC.Batch = {
    start: { source: "source", sequence: 0L, },
    end: { source: "source", sequence: 0L, },
    high_water: 0L,
    events: [],
  }
  let decoder = @MoonCDC.BatchDecoder::new(max_total_units=16777216)
  decoder.feed(batch.to_jsonl())
  assert_eq(decoder.finish(), batch)
  assert_true(
    try {
      @MoonCDC.BatchDecoder::new(
        max_line_units=16777472,
        max_total_units=16777216,
      )
      |> ignore
      false
    } catch {
      _ => true
    },
  )
}
