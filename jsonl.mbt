///|
/// Framed JSONL: header, event records and a required commit trailer.
pub fn Batch::to_jsonl(self : Batch) -> String raise CdcError {
  self.validate()
  let output = StringBuilder()
  let header : Json = {
    "kind": "header",
    "format": "mooncdc.jsonl.v1",
    "start": self.start.to_wire(),
    "high_water": self.high_water.to_string(),
  }
  output.write_string(header.stringify())
  output.write_char('\n')
  for event in self.events {
    let record : Json = { "kind": "event", "event": event.to_wire() }
    output.write_string(record.stringify())
    output.write_char('\n')
  }
  let trailer : Json = {
    "kind": "commit",
    "end": self.end.to_wire(),
    "count": self.events.length().to_string(),
  }
  output.write_string(trailer.stringify())
  output.write_char('\n')
  output.to_string()
}

///|
pub struct BatchDecoder {
  max_events : Int32
  max_line_units : Int32
  max_total_units : Int32
  mut total : Int32
  mut pending : String
  mut start : Cursor?
  mut end : Cursor?
  mut high_water : Int64
  events : Array[Event]
  mut failed : Bool
  mut finished : Bool
}

///|
pub fn BatchDecoder::new(
  max_events~ : Int32 = 100000,
  max_line_units~ : Int32 = 16777216,
  max_total_units~ : Int32 = 67108864,
) -> BatchDecoder raise CdcError {
  if max_events <= 0 || max_line_units <= 0 || max_total_units < max_line_units {
    raise Invalid("Invalid JSONL decoder limits")
  }
  {
    max_events,
    max_line_units,
    max_total_units,
    total: 0,
    pending: "",
    start: None,
    end: None,
    high_water: 0L,
    events: [],
    failed: false,
    finished: false,
  }
}

///|
fn BatchDecoder::line(
  self : BatchDecoder,
  line : String,
) -> Unit raise CdcError {
  if line.length() > self.max_line_units {
    raise Invalid("JSONL line limit exceeded")
  }
  let line = line.trim().to_owned()
  if line.is_empty() {
    raise Invalid("Blank lines are not allowed inside a framed batch")
  }
  if self.end is Some(_) {
    raise Invalid("Record after commit trailer")
  }
  let record = parse_json(line)
  match string_field(record, "kind") {
    "header" => {
      if self.start is Some(_) {
        raise Invalid("Duplicate batch header")
      }
      if string_field(record, "format") != "mooncdc.jsonl.v1" {
        raise Invalid("Unsupported JSONL format")
      }
      let start = Cursor::from_wire(field(record, "start"))
      let high_water = integer_field(record, "high_water")
      if high_water < start.sequence {
        raise Invalid("JSONL high-water precedes start")
      }
      self.start = Some(start)
      self.high_water = high_water
    }
    "event" => {
      let start = match self.start {
        Some(cursor) => cursor
        None => raise Invalid("Event precedes header")
      }
      if self.events.length() >= self.max_events {
        raise Invalid("JSONL event limit exceeded")
      }
      let event = Event::from_wire(field(record, "event"))
      let previous = if self.events.is_empty() {
        start.sequence
      } else {
        self.events[self.events.length() - 1].sequence
      }
      if event.sequence <= previous || event.sequence > self.high_water {
        raise Invalid("JSONL event order or watermark invalid")
      }
      self.events.push(event)
    }
    "commit" => {
      let start = match self.start {
        Some(cursor) => cursor
        None => raise Invalid("Commit precedes header")
      }
      let end = Cursor::from_wire(field(record, "end"))
      if integer_field(record, "count") != self.events.length().to_int64() {
        raise Invalid("JSONL event count mismatch")
      }
      let batch = Batch::{
        start,
        end,
        high_water: self.high_water,
        events: self.events,
      }
      batch.validate()
      self.end = Some(end)
    }
    _ => raise Invalid("Unknown JSONL record kind")
  }
}

///|
pub fn BatchDecoder::feed(
  self : BatchDecoder,
  chunk : String,
) -> Unit raise CdcError {
  if self.failed || self.finished {
    raise Invalid("Decoder is failed or finished")
  }
  errdefer {
    self.failed = true
  }
  if chunk.length() > self.max_total_units - self.total {
    raise Invalid("JSONL input limit exceeded")
  }
  self.total += chunk.length()
  let combined = self.pending + chunk
  let mut offset = 0
  for index in 0..<combined.length() {
    if combined[index].to_int() == 10 {
      self.line(combined[offset:index].to_owned())
      offset = index + 1
    }
  }
  self.pending = combined[offset:].to_owned()
  if self.pending.length() > self.max_line_units {
    raise Invalid("Unterminated JSONL line limit exceeded")
  }
}

///|
pub fn BatchDecoder::finish(self : BatchDecoder) -> Batch raise CdcError {
  if self.failed || self.finished {
    raise Invalid("Decoder is failed or finished")
  }
  errdefer {
    self.failed = true
  }
  if !self.pending.is_empty() {
    self.line(self.pending)
    self.pending = ""
  }
  let start = match self.start {
    Some(cursor) => cursor
    None => raise Invalid("Missing JSONL header")
  }
  let end = match self.end {
    Some(cursor) => cursor
    None => raise Invalid("Incomplete JSONL batch: missing commit")
  }
  self.finished = true
  { start, end, high_water: self.high_water, events: self.events.copy(), }
}

///|
pub fn Batch::from_jsonl(text : String) -> Batch raise CdcError {
  let decoder = BatchDecoder::new()
  decoder.feed(text)
  decoder.finish()
}

///|
pub fn Snapshot::to_jsonl(self : Snapshot) -> String raise CdcError {
  self.validate()
  let lines : Array[String] = []
  let header : Json = {
    "kind": "snapshot",
    "format": "mooncdc.snapshot-jsonl.v1",
    "cursor": self.cursor.to_wire(),
    "schemas": Json::array(self.schemas().map(table => table.to_wire())),
  }
  lines.push(header.stringify())
  for table in self.tables {
    for row in table.rows {
      let record : Json = {
        "kind": "row",
        "table": table.schema.name,
        "row": row.to_wire(),
      }
      lines.push(record.stringify())
    }
  }
  let trailer : Json = {
    "kind": "commit",
    "count": self.row_count().to_string(),
  }
  lines.push(trailer.stringify())
  lines.join("\n") + "\n"
}

///|
pub fn Snapshot::from_jsonl(
  text : String,
  max_rows~ : Int32 = 100000,
  max_units~ : Int32 = 67108864,
) -> Snapshot raise CdcError {
  if max_rows <= 0 || max_units <= 0 || text.length() > max_units {
    raise Invalid("Snapshot input limit exceeded")
  }
  let mut cursor : Cursor? = None
  let tables : Array[TableSnapshot] = []
  let mut committed = false
  let mut count = 0
  let lines = text.split("\n").to_array()
  for index, line in lines {
    if index == lines.length() - 1 && line.is_empty() {
      break
    }
    if committed {
      raise Invalid("Record after snapshot commit")
    }
    let value = parse_json(line.to_owned())
    match string_field(value, "kind") {
      "snapshot" => {
        if cursor is Some(_) ||
          string_field(value, "format") != "mooncdc.snapshot-jsonl.v1" {
          raise Invalid("Invalid snapshot header")
        }
        cursor = Some(Cursor::from_wire(field(value, "cursor")))
        for schema in array_field(value, "schemas") {
          tables.push({ schema: Table::from_wire(schema), rows: [], })
        }
      }
      "row" => {
        if cursor is None || count >= max_rows {
          raise Invalid("Snapshot row limit or missing header")
        }
        let name = string_field(value, "table")
        let row = Row::from_wire(field(value, "row"))
        let mut found = false
        for table in tables {
          if table.schema.name == name {
            row.validate(table.schema)
            table.rows.push(row)
            found = true
            break
          }
        }
        if !found {
          raise Invalid("Unknown snapshot row table")
        }
        count += 1
      }
      "commit" => {
        if cursor is None || integer_field(value, "count") != count.to_int64() {
          raise Invalid("Invalid snapshot commit")
        }
        committed = true
      }
      _ => raise Invalid("Unknown snapshot record")
    }
  }
  if !committed {
    raise Invalid("Incomplete snapshot")
  }
  let cursor = match cursor {
    Some(cursor) => cursor
    None => raise Invalid("Missing snapshot header")
  }
  let snapshot = Snapshot::{ cursor, tables, }
  snapshot.validate()
  snapshot
}
