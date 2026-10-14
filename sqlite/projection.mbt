///|
pub fn Database::projection_cursor(self : Database) -> @cdc.Cursor raise {
  let rows = self.query(
    "SELECT format,source_id,sequence FROM _mooncdc_projection WHERE singleton=1",
    [],
    max_rows=2,
  )
  if rows.length() != 1 || integer(rows[0].values[0]) != 1L {
    raise StoreError("Missing or unsupported projection metadata")
  }
  let cursor = @cdc.Cursor::{
    source: text(rows[0].values[1]),
    sequence: integer(rows[0].values[2]),
  }
  cursor.validate()
  cursor
}

///|
pub fn Database::projection_tables(self : Database) -> Array[@cdc.Table] raise {
  @cdc.schemas_from_wire(
    text(
      self.scalar(
        "SELECT schema_json FROM _mooncdc_projection WHERE singleton=1",
        [],
      ),
    ),
  )
}

///|
pub fn Database::verify_projection(self : Database) -> Unit raise {
  self.projection_cursor() |> ignore
  for table in self.projection_tables() {
    if self.definition(table.name, "table") !=
      table.create_projection_sql(table.name) {
      raise StoreError("Projection schema changed: " + table.name)
    }
    if !self
      .query(
        "SELECT name FROM sqlite_schema WHERE type='trigger' AND tbl_name=?",
        [Text(table.name)],
      )
      .is_empty() {
      raise StoreError("Projection tables must not have side-effect triggers")
    }
  }
}

///|
pub fn Database::initialize_projection(
  self : Database,
  snapshot : @cdc.Snapshot,
) -> Unit raise {
  snapshot.validate()
  self.begin(true)
  defer self.rollback()
  if !self
    .query("SELECT name FROM sqlite_schema WHERE name GLOB '_mooncdc_*'", [])
    .is_empty() {
    raise StoreError(
      "Target has MoonCDC metadata; initialization never overwrites it",
    )
  }
  for table in snapshot.tables {
    if self.has_object(table.schema.name) {
      raise StoreError("Target table already exists: " + table.schema.name)
    }
  }
  for sql in @cdc.target_schema_sql() {
    self.execute(sql, []) |> ignore
  }
  for table in snapshot.tables {
    self.execute(table.schema.create_projection_sql(table.schema.name), [])
    |> ignore
    for row in table.rows {
      let insert = table.schema.insert_statement(row)
      self.execute(insert.sql, insert.parameters) |> ignore
    }
  }
  self.execute("INSERT INTO _mooncdc_projection VALUES (1,1,?,?,?)", [
    Text(snapshot.cursor.source),
    Integer(snapshot.cursor.sequence),
    Text(@cdc.schemas_to_wire(snapshot.schemas())),
  ])
  |> ignore
  self.commit()
}

///|
fn Database::require_before(
  self : Database,
  table : @cdc.Table,
  before : @cdc.Row,
) -> Unit raise {
  let lookup = table.lookup_statement(before)
  let rows = self.query(lookup.sql, lookup.parameters, max_rows=2)
  if rows.length() != 1 || rows[0] != before {
    raise StoreError("Projection diverged from before-image in " + table.name)
  }
}

///|
fn Database::apply_event(
  self : Database,
  table : @cdc.Table,
  event : @cdc.Event,
) -> Unit raise {
  event.validate()
  match (event.operation, event.before, event.after) {
    (Insert, None, Some(after)) => {
      let statement = table.insert_statement(after)
      self.execute(statement.sql, statement.parameters) |> ignore
    }
    (Update, Some(before), Some(after)) => {
      self.require_before(table, before)
      let statement = table.update_statement(before, after)
      if self.execute(statement.sql, statement.parameters) != 1L {
        raise StoreError("Update did not affect exactly one projection row")
      }
    }
    (Delete, Some(before), None) => {
      self.require_before(table, before)
      let statement = table.delete_statement(before)
      if self.execute(statement.sql, statement.parameters) != 1L {
        raise StoreError("Delete did not affect exactly one projection row")
      }
    }
    _ => raise StoreError("Invalid operation images")
  }
}

///|
/// Returns newly applied events; an already committed batch returns zero.
pub fn Database::apply_batch(
  self : Database,
  batch : @cdc.Batch,
) -> Int32 raise {
  batch.validate()
  self.begin(true)
  defer self.rollback()
  self.verify_projection()
  let current = self.projection_cursor()
  if current.source != batch.start.source {
    raise StoreError("Projection belongs to a different source")
  }
  if current.sequence >= batch.end.sequence {
    self.commit()
    return 0
  }
  if current != batch.start {
    raise StoreError("Batch does not start at the projection cursor")
  }
  let tables = self.projection_tables()
  for event in batch.events {
    self.apply_event(@cdc.find_table(tables, event.table), event)
  }
  self.execute("UPDATE _mooncdc_projection SET sequence=? WHERE singleton=1", [
    Integer(batch.end.sequence),
  ])
  |> ignore
  self.commit()
  batch.events.length()
}

///|
/// Resume from the durable target cursor and repair a lagging source ack.
pub fn synchronize(
  source : Database,
  target : Database,
  consumer : String,
  batch_limit~ : Int32 = 1000,
  max_batches~ : Int32 = 100,
) -> Int32 raise {
  if max_batches <= 0 || max_batches > 100000 {
    raise StoreError("Invalid synchronization batch budget")
  }
  source.verify_capture()
  target.verify_projection()
  if source.capture_tables() != target.projection_tables() {
    raise StoreError("Source and projection schema manifests differ")
  }
  let mut applied = 0
  for _ in 0..<max_batches {
    let target_cursor = target.projection_cursor()
    let acknowledged = source.consumer_cursor(consumer)
    if acknowledged.source != target_cursor.source ||
      acknowledged.sequence > target_cursor.sequence {
      raise StoreError(
        "Source acknowledgement is ahead of or unrelated to target",
      )
    }
    if acknowledged != target_cursor {
      source.acknowledge(consumer, acknowledged, target_cursor)
    }
    let batch = source.read_batch(target_cursor, limit=batch_limit)
    if batch.events.is_empty() {
      break
    }
    applied += target.apply_batch(batch)
    source.acknowledge(consumer, target_cursor, batch.end)
    if batch.end.sequence == batch.high_water {
      break
    }
  }
  applied
}
