///|
/// Rechunk a transport without losing empty cursor intervals introduced by filtering.
/// The byte-independent budget measures serialized UTF-16 code units, not UTF-8 bytes.
pub fn Batch::split(
  self : Batch,
  max_events~ : Int32 = 1000,
  max_wire_units~ : Int32 = 16777216,
) -> Array[Batch] raise CdcError {
  self.validate()
  if max_events <= 0 || max_wire_units <= 0 {
    raise Invalid("Invalid batch split budget")
  }
  let result : Array[Batch] = []
  let mut start = self.start
  let mut events : Array[Event] = []
  let mut units = 0
  for event in self.events {
    let size = event.to_wire().stringify().length()
    if size > max_wire_units {
      raise Invalid("A single event exceeds the split budget")
    }
    if !events.is_empty() &&
      (events.length() >= max_events || size > max_wire_units - units) {
      let end = Cursor::{
        ..start,
        sequence: events[events.length() - 1].sequence,
      }
      result.push({ start, end, high_water: self.high_water, events, })
      start = end
      events = []
      units = 0
    }
    events.push(event)
    units += size
  }
  result.push({ start, end: self.end, high_water: self.high_water, events, })
  result
}

///|
/// Join adjacent envelopes. Gaps, overlaps and unrelated source identities fail closed.
pub fn merge_batches(
  batches : Array[Batch],
  max_events~ : Int32 = 100000,
) -> Batch raise CdcError {
  if batches.is_empty() || max_events <= 0 {
    raise Invalid("Expected batches and positive event budget")
  }
  let first = batches[0]
  first.validate()
  let mut end = first.start
  let mut high_water = first.high_water
  let events : Array[Event] = []
  for batch in batches {
    batch.validate()
    if batch.start != end {
      raise Conflict("Batches are not adjacent")
    }
    if batch.events.length() > max_events - events.length() {
      raise Invalid("Merged batch exceeds event budget")
    }
    for event in batch.events {
      events.push(event)
    }
    end = batch.end
    high_water = high_water.max(batch.high_water)
  }
  let merged = Batch::{ start: first.start, end, high_water, events, }
  merged.validate()
  merged
}

///|
/// Human-readable activity summary; counts row events rather than source transactions.
pub fn Batch::summarize(
  self : Batch,
  schemas : Array[Table],
) -> Json raise CdcError {
  self.validate()
  let tables : Array[Json] = []
  let names : Map[String, Bool] = Map([])
  for schema in schemas {
    schema.validate()
    if names.contains(schema.name) {
      raise Invalid("Duplicate summary schema")
    }
    names[schema.name] = true
    let mut inserts = 0
    let mut updates = 0
    let mut deletes = 0
    let mut key_changes = 0
    let mut unchanged_updates = 0
    let mut wire_units = 0
    let changed = FixedArray::make(schema.columns.length(), 0)
    for event in self.events {
      if event.table != schema.name {
        continue
      }
      if event.before is Some(row) {
        row.validate(schema)
      }
      if event.after is Some(row) {
        row.validate(schema)
      }
      wire_units += event.to_wire().stringify().length()
      match event.operation {
        Insert => inserts += 1
        Delete => deletes += 1
        Update => {
          updates += 1
          let before = event.before.unwrap()
          let after = event.after.unwrap()
          if before == after {
            unchanged_updates += 1
          }
          if before.key(schema) != after.key(schema) {
            key_changes += 1
          }
          for index, value in before.values {
            if value != after.values[index] {
              changed[index] += 1
            }
          }
        }
      }
    }
    let columns : Array[Json] = []
    for index, column in schema.columns {
      if changed[index] != 0 {
        columns.push({ "column": column.name, "updates": changed[index] })
      }
    }
    tables.push({
      "table": schema.name,
      "inserts": inserts,
      "updates": updates,
      "deletes": deletes,
      "key_changes": key_changes,
      "unchanged_updates": unchanged_updates,
      "wire_units": wire_units,
      "changed_columns": Json::array(columns),
    })
  }
  for event in self.events {
    if !names.contains(event.table) {
      raise Invalid("Summary is missing an event table schema")
    }
  }
  {
    "start": self.start.to_wire(),
    "end": self.end.to_wire(),
    "high_water": self.high_water.to_string(),
    "events": self.events.length(),
    "remaining_sequence_distance": (self.high_water - self.end.sequence).to_string(),
    "tables": Json::array(tables),
  }
}
