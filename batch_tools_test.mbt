///|
test "split and merge preserve filtered cursor gaps including trailing emptiness" {
  let start = @MoonCDC.Cursor::{ source: "source", sequence: 0L, }
  let events : Array[@MoonCDC.Event] = [
    {
      sequence: 2L,
      table: "items",
      operation: Insert,
      before: None,
      after: Some({ values: [Integer(2L)], }),
    },
    {
      sequence: 8L,
      table: "items",
      operation: Delete,
      before: Some({ values: [Integer(8L)], }),
      after: None,
    },
  ]
  let batch = @MoonCDC.Batch::{
    start,
    end: { ..start, sequence: 10L, },
    high_water: 12L,
    events,
  }
  let parts = batch.split(max_events=1)
  assert_eq(parts.length(), 2)
  assert_eq(parts[1].start.sequence, 2L)
  assert_eq(@MoonCDC.merge_batches(parts), batch)
  let empty = @MoonCDC.Batch::{ ..batch, events: [], }
  assert_eq(@MoonCDC.merge_batches(empty.split()), empty)
  assert_true(
    try {
      @MoonCDC.merge_batches([parts[1], parts[0]]) |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      batch.split(max_wire_units=1) |> ignore
      false
    } catch {
      _ => true
    },
  )
}
