///|
pub fn Database::snapshot(
  self : Database,
  consumer : String,
  max_rows~ : Int32 = 100000,
) -> @cdc.Snapshot raise {
  @cdc.check_name(consumer)
  if max_rows <= 0 || max_rows > 1000000 {
    raise StoreError("Snapshot row limit must be 1..1000000")
  }
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  if !self
    .query("SELECT name FROM _mooncdc_consumers WHERE name=?", [Text(consumer)])
    .is_empty() {
    raise StoreError(
      "Consumer already exists; use a new name for reinitialization",
    )
  }
  let cursor = self.source_cursor()
  let result : Array[@cdc.TableSnapshot] = []
  let mut remaining = max_rows
  for table in self.capture_tables() {
    let rows = self.query(table.select_sql(), [], max_rows=remaining)
    for row in rows {
      row.validate(table)
    }
    remaining -= rows.length()
    result.push({ schema: table, rows, })
  }
  let snapshot = @cdc.Snapshot::{ cursor, tables: result, }
  snapshot.validate()
  self.execute("INSERT INTO _mooncdc_consumers(name,sequence) VALUES (?,?)", [
    Text(consumer),
    Integer(cursor.sequence),
  ])
  |> ignore
  self.commit()
  snapshot
}

///|
pub fn Database::read_batch(
  self : Database,
  cursor : @cdc.Cursor,
  limit~ : Int32 = 1000,
  max_wire_units~ : Int32 = 16777216,
) -> @cdc.Batch raise {
  if limit <= 0 || limit > 100000 || max_wire_units <= 0 {
    raise StoreError("Invalid batch limits")
  }
  self.begin(false)
  defer self.rollback()
  self.verify_capture()
  let high_water = self.source_cursor()
  @cdc.validate_cursor(cursor, high_water, self.retention_floor())
  let statement = self.prepare(
    "SELECT sequence,table_name,operation,before_row,after_row FROM _mooncdc_events WHERE sequence>? ORDER BY sequence LIMIT ?",
    [Integer(cursor.sequence), Integer(limit.to_int64())],
  )
  defer (statement.finalize() catch { _ => () })
  let tables = self.capture_tables()
  let events : Array[@cdc.Event] = []
  let mut last = cursor.sequence
  let mut units = 0
  while statement.step() {
    let sequence = integer(from_sqlite(statement.column(index=0)))
    if last == 9223372036854775807L || sequence != last + 1L {
      raise StoreError("Event journal has a gap")
    }
    let before = decode_image(from_sqlite(statement.column(index=3)))
    let after = decode_image(from_sqlite(statement.column(index=4)))
    let event = @cdc.Event::{
      sequence,
      table: text(from_sqlite(statement.column(index=1))),
      operation: @cdc.Operation::parse(
        text(from_sqlite(statement.column(index=2))),
      ),
      before,
      after,
    }
    event.validate()
    let table = @cdc.find_table(tables, event.table)
    if before is Some(image) {
      image.validate(table)
    }
    if after is Some(image) {
      image.validate(table)
    }
    let size = event.to_wire().stringify().length()
    if size > max_wire_units {
      raise StoreError("A single event exceeds the wire budget")
    }
    if units > max_wire_units - size {
      break
    }
    units += size
    events.push(event)
    last = sequence
  }
  if events.is_empty() && last != high_water.sequence {
    raise StoreError("Journal tail is missing")
  }
  let batch = @cdc.Batch::{
    start: cursor,
    end: { source: cursor.source, sequence: last, },
    high_water: high_water.sequence,
    events,
  }
  batch.validate()
  self.commit()
  batch
}

///|
fn decode_image(value : @cdc.Value) -> @cdc.Row? raise {
  match value {
    Null => None
    Text(v) => Some(@cdc.Row::from_wire(@cdc.parse_json(v)))
    _ => raise StoreError("Invalid journal row image")
  }
}

///|
pub fn Database::consumer_cursor(
  self : Database,
  name : String,
) -> @cdc.Cursor raise {
  let rows = self.query(
    "SELECT sequence,paused FROM _mooncdc_consumers WHERE name=?",
    [Text(name)],
    max_rows=2,
  )
  if rows.length() != 1 {
    raise StoreError("Unknown consumer: " + name)
  }
  if integer(rows[0].values[1]) != 0L {
    raise StoreError("Consumer is paused: " + name)
  }
  let source = self.source_cursor()
  let cursor = @cdc.Cursor::{
    source: source.source,
    sequence: integer(rows[0].values[0]),
  }
  @cdc.validate_cursor(cursor, source, self.retention_floor())
  cursor
}

///|
pub fn Database::acknowledge(
  self : Database,
  name : String,
  expected : @cdc.Cursor,
  next : @cdc.Cursor,
) -> Unit raise {
  self.begin(true)
  defer self.rollback()
  let current = self.consumer_cursor(name)
  @cdc.validate_cursor(next, self.source_cursor(), self.retention_floor())
  if expected.source != next.source || next.sequence < expected.sequence {
    raise StoreError("Acknowledgement cannot change source or move backwards")
  }
  if current == next {
    self.commit()
    return
  }
  if current != expected {
    raise StoreError("Consumer cursor changed concurrently")
  }
  self.execute("UPDATE _mooncdc_consumers SET sequence=? WHERE name=?", [
    Integer(next.sequence),
    Text(name),
  ])
  |> ignore
  self.commit()
}

///|
pub fn Database::pause_consumer(
  self : Database,
  name : String,
  paused : Bool,
) -> Unit raise {
  let count = self.execute(
    "UPDATE _mooncdc_consumers SET paused=? WHERE name=?",
    [Integer(if paused { 1L } else { 0L }), Text(name)],
  )
  if count != 1L {
    raise StoreError("Unknown consumer: " + name)
  }
}

///|
pub fn Database::drop_consumer(self : Database, name : String) -> Unit raise {
  let count = self.execute("DELETE FROM _mooncdc_consumers WHERE name=?", [
    Text(name),
  ])
  if count != 1L {
    raise StoreError("Unknown consumer: " + name)
  }
}

///|
pub fn Database::prune(self : Database) -> Int64 raise {
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  let low = self.scalar("SELECT min(sequence) FROM _mooncdc_consumers", [])
  let low = match low {
    Integer(v) => v
    _ => raise StoreError("No consumers; refusing automatic journal deletion")
  }
  let source = self.source_cursor()
  @cdc.validate_cursor(
    { source: source.source, sequence: low, },
    source,
    self.retention_floor(),
  )
  let deleted = self.execute("DELETE FROM _mooncdc_events WHERE sequence<=?", [
    Integer(low),
  ])
  self.execute("UPDATE _mooncdc_meta SET floor=? WHERE singleton=1", [
    Integer(low),
  ])
  |> ignore
  self.commit()
  deleted
}
