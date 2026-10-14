///|
pub fn Database::status(self : Database) -> Json raise {
  self.begin(false)
  defer self.rollback()
  self.verify_capture()
  let cursor = self.source_cursor()
  let floor = self.retention_floor()
  let consumers : Array[Json] = self
    .query(
      "SELECT name,sequence,paused FROM _mooncdc_consumers ORDER BY name",
      [],
    )
    .map(row => {
      let position = integer(row.values[1])
      {
        "name": text(row.values[0]),
        "sequence": position.to_string(),
        "paused": integer(row.values[2]) != 0L,
        "lag": (cursor.sequence - position).to_string(),
        "stale": position < floor,
      }
    })
  let tables : Array[Json] = self
    .capture_tables()
    .map(table => {
      let rows = integer(
        self.scalar(
          "SELECT count(*) FROM " + @cdc.quote_identifier(table.name),
          [],
        ),
      )
      let pending = integer(
        self.scalar("SELECT count(*) FROM _mooncdc_events WHERE table_name=?", [
          Text(table.name),
        ]),
      )
      {
        "schema": table.to_wire(),
        "rows": rows.to_string(),
        "retained_events": pending.to_string(),
      }
    })
  let journal_rows = integer(
    self.scalar("SELECT count(*) FROM _mooncdc_events", []),
  )
  let report : Json = {
    "format": "mooncdc.status.v1",
    "cursor": cursor.to_wire(),
    "floor": floor.to_string(),
    "retained_events": journal_rows.to_string(),
    "journal_contiguous": journal_rows == cursor.sequence - floor,
    "tables": Json::array(tables),
    "consumers": Json::array(consumers),
  }
  self.commit()
  report
}

///|
/// Read-only preview. Does not create metadata or modify user tables.
pub fn Database::plan_capture(
  self : Database,
  names : Array[String],
) -> Json raise {
  let details : Array[Json] = []
  let mut eligible = !names.is_empty() && names.length() <= 128
  let seen : Map[String, Bool] = Map([])
  for index, name in names {
    let detail : Json = try {
      if seen.contains(name.to_lower()) {
        raise StoreError("Duplicate requested table")
      }
      seen[name.to_lower()] = true
      let table = self.inspect_table(name)
      let keys = table
        .key_indexes()
        .map(i => @cdc.quote_identifier(table.columns[i].name) + " IS NULL")
      if !self
        .query(
          "SELECT 1 FROM " +
          @cdc.quote_identifier(name) +
          " WHERE " +
          keys.join(" OR ") +
          " LIMIT 1",
          [],
        )
        .is_empty() {
        raise StoreError("Existing primary key contains NULL")
      }
      let statements = [@cdc.Insert, @cdc.Update, @cdc.Delete].map(operation => {
        Json::string(table.trigger_sql(index + 1, operation))
      })
      {
        "name": name,
        "eligible": true,
        "schema": table.to_wire(),
        "triggers": Json::array(statements),
      }
    } catch {
      error => {
        eligible = false
        { "name": name, "eligible": false, "error": error.to_string() }
      }
    }
    details.push(detail)
  }
  let occupied = !self
    .query("SELECT name FROM sqlite_schema WHERE name GLOB '_mooncdc_*'", [])
    .is_empty()
  {
    "eligible": eligible && !occupied,
    "metadata_already_exists": occupied,
    "tables": Json::array(details),
    "capture_mode": "persistent-after-row-triggers",
    "modifies_source_schema": true,
  }
}

///|
pub fn Database::audit_journal(
  self : Database,
  max_events~ : Int32 = 100000,
) -> Json raise {
  if max_events <= 0 || max_events > 1000000 {
    raise StoreError("Invalid journal audit budget")
  }
  self.begin(false)
  defer self.rollback()
  self.verify_capture()
  let cursor = self.source_cursor()
  let floor = self.retention_floor()
  let rows = self.query(
    "SELECT sequence,table_name,operation,before_row,after_row FROM _mooncdc_events ORDER BY sequence",
    [],
    max_rows=max_events,
  )
  let tables = self.capture_tables()
  let mut previous = floor
  let mut inserts = 0
  let mut updates = 0
  let mut deletes = 0
  for row in rows {
    let sequence = integer(row.values[0])
    if previous == 9223372036854775807L || sequence != previous + 1L {
      raise StoreError("Journal has a missing or reordered event")
    }
    let event = @cdc.Event::{
      sequence,
      table: text(row.values[1]),
      operation: @cdc.Operation::parse(text(row.values[2])),
      before: decode_image(row.values[3]),
      after: decode_image(row.values[4]),
    }
    event.validate()
    let table = @cdc.find_table(tables, event.table)
    if event.before is Some(before) {
      before.validate(table)
    }
    if event.after is Some(after) {
      after.validate(table)
    }
    match event.operation {
      Insert => inserts += 1
      Update => updates += 1
      Delete => deletes += 1
    }
    previous = sequence
  }
  if previous != cursor.sequence {
    raise StoreError("Journal tail does not match high-water mark")
  }
  self.commit()
  {
    "valid": true,
    "cursor": cursor.to_wire(),
    "floor": floor.to_string(),
    "checked": rows.length(),
    "inserts": inserts,
    "updates": updates,
    "deletes": deletes,
  }
}

///|
/// Compare only matching watermarks; refuse to label normal replication lag as corruption.
pub fn audit_projection(
  source : Database,
  target : Database,
  max_rows~ : Int32 = 100000,
  sample_limit~ : Int32 = 20,
) -> @cdc.AuditReport raise {
  if max_rows <= 0 {
    raise StoreError("Invalid row audit budget")
  }
  source.begin(false)
  defer source.rollback()
  target.begin(false)
  defer target.rollback()
  source.verify_capture()
  target.verify_projection()
  let cursor = source.source_cursor()
  if cursor != target.projection_cursor() {
    raise StoreError("Catch up the projection before auditing content")
  }
  let tables = source.capture_tables()
  if tables != target.projection_tables() {
    raise StoreError("Audit schema mismatch")
  }
  let expected : Array[@cdc.TableSnapshot] = []
  let actual : Array[@cdc.TableSnapshot] = []
  let mut remaining = max_rows
  for table in tables {
    let left = source.query(table.select_sql(), [], max_rows=remaining)
    let right = target.query(table.select_sql(), [], max_rows=remaining)
    remaining -= left.length().max(right.length())
    expected.push({ schema: table, rows: left, })
    actual.push({ schema: table, rows: right, })
  }
  let report = @cdc.compare_snapshots(
    { cursor, tables: expected, },
    { cursor, tables: actual, },
    sample_limit~,
  )
  target.commit()
  source.commit()
  report
}
