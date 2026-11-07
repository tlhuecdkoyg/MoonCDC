///|
fn chunk_review_batch(text : String) -> @MoonCDC.Batch {
  {
    start: { source: "source", sequence: 0L, },
    end: { source: "source", sequence: 1L, },
    high_water: 1L,
    events: [
      {
        sequence: 1L,
        table: "items",
        operation: Insert,
        before: None,
        after: Some({ values: [Integer(1L), Text(text)], }),
      },
    ],
  }
}

///|
fn feed_scalar_chunks(
  decoder : @MoonCDC.BatchDecoder,
  text : String,
  size : Int32,
) -> Unit raise {
  let characters = text.to_array()
  let mut offset = 0
  while offset < characters.length() {
    let end = (offset + size).min(characters.length())
    decoder.feed(String::from_array(characters[offset:end]))
    offset = end
  }
}

///|
test "incremental JSONL accepts a long ASCII line one character at a time" {
  let characters = Array::make(80000, 'a')
  let batch = chunk_review_batch(String::from_array(characters[:]))
  let decoder = @MoonCDC.BatchDecoder::new()
  feed_scalar_chunks(decoder, batch.to_jsonl(), 1)
  assert_eq(decoder.finish(), batch)
}

///|
test "incremental JSONL preserves scalar Unicode chunks CRLF and unterminated final commit" {
  let batch = chunk_review_batch("\uFEFF\u0000😀\r\n\t\"\\\u2028\u2029尾")
  let wire = batch.to_jsonl()
  for
    framed in [
      wire,
      wire.replace_all(old="\n", new="\r\n"),
      wire[0:wire.length() - 1].to_owned(),
    ] {
    for size in [1, 2, 3, 7, 64] {
      let decoder = @MoonCDC.BatchDecoder::new()
      decoder.feed("")
      feed_scalar_chunks(decoder, framed, size)
      assert_eq(decoder.finish(), batch)
      assert_true(
        try {
          decoder.finish() |> ignore
          false
        } catch {
          _ => true
        },
      )
      assert_true(
        try {
          decoder.feed("")
          false
        } catch {
          _ => true
        },
      )
    }
  }
}

///|
test "incremental JSONL enforces exact line total and event limits and poisons failures" {
  let batch = chunk_review_batch("a bounded line 😀")
  let wire = batch.to_jsonl()
  let mut longest = 0
  for line in wire.split("\n") {
    longest = longest.max(line.length())
  }
  let exact = @MoonCDC.BatchDecoder::new(
    max_events=1,
    max_line_units=longest,
    max_total_units=wire.length(),
  )
  feed_scalar_chunks(exact, wire, 1)
  assert_eq(exact.finish(), batch)
  let short_line = @MoonCDC.BatchDecoder::new(
    max_line_units=longest - 1,
    max_total_units=wire.length(),
  )
  assert_true(
    try {
      feed_scalar_chunks(short_line, wire, 1)
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      short_line.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      short_line.feed("")
      false
    } catch {
      _ => true
    },
  )
  let short_total = @MoonCDC.BatchDecoder::new(
    max_line_units=longest,
    max_total_units=wire.length() - 1,
  )
  short_total.feed(wire[0:wire.length() - 1].to_owned())
  assert_true(
    try {
      short_total.feed("\n")
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      short_total.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
  let second = @MoonCDC.Event::{
    ..batch.events[0],
    sequence: 2L,
    after: Some({ values: [Integer(2L), Text("second")], }),
  }
  let multiple = @MoonCDC.Batch::{
    ..batch,
    end: { ..batch.end, sequence: 2L, },
    high_water: 2L,
    events: [batch.events[0], second],
  }
  let count_limited = @MoonCDC.BatchDecoder::new(max_events=1)
  assert_true(
    try {
      feed_scalar_chunks(count_limited, multiple.to_jsonl(), 1)
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      count_limited.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
}

///|
test "incremental JSONL rejects missing trailers blank records and records after commit" {
  let batch = chunk_review_batch("payload")
  let wire = batch.to_jsonl()
  let header = wire.split("\n").to_array()[0].to_owned() + "\n"
  let incomplete = @MoonCDC.BatchDecoder::new()
  feed_scalar_chunks(incomplete, header, 1)
  assert_true(
    try {
      incomplete.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      incomplete.feed(wire)
      false
    } catch {
      _ => true
    },
  )
  let blank = @MoonCDC.BatchDecoder::new()
  blank.feed(header)
  assert_true(
    try {
      blank.feed("\n")
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      blank.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
  let extra = @MoonCDC.BatchDecoder::new()
  feed_scalar_chunks(extra, wire, 1)
  assert_true(
    try {
      extra.feed("{}\n")
      false
    } catch {
      _ => true
    },
  )
  assert_true(
    try {
      extra.finish() |> ignore
      false
    } catch {
      _ => true
    },
  )
}
