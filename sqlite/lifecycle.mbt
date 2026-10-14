///|
/// Register a new consumer at an externally persisted checkpoint (for restore).
/// The caller must already possess the corresponding snapshot or target data.
pub fn Database::register_checkpoint(
  self : Database,
  name : String,
  cursor : @cdc.Cursor,
) -> Unit raise {
  @cdc.check_name(name)
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  @cdc.validate_cursor(cursor, self.source_cursor(), self.retention_floor())
  if !self
    .query("SELECT name FROM _mooncdc_consumers WHERE name=?", [Text(name)])
    .is_empty() {
    raise StoreError(
      "Checkpoint registration never overwrites an existing consumer",
    )
  }
  self.execute("INSERT INTO _mooncdc_consumers(name,sequence) VALUES(?,?)", [
    Text(name),
    Integer(cursor.sequence),
  ])
  |> ignore
  self.commit()
}

///|
/// Clone a consumer position after separately cloning its materialized target.
pub fn Database::fork_consumer(
  self : Database,
  original : String,
  name : String,
) -> @cdc.Cursor raise {
  @cdc.check_name(name)
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  let cursor = self.consumer_cursor(original)
  if !self
    .query("SELECT name FROM _mooncdc_consumers WHERE name=?", [Text(name)])
    .is_empty() {
    raise StoreError("Fork destination consumer already exists")
  }
  self.execute("INSERT INTO _mooncdc_consumers(name,sequence) VALUES(?,?)", [
    Text(name),
    Integer(cursor.sequence),
  ])
  |> ignore
  self.commit()
  cursor
}

///|
/// Preview retention without removing events, including paused consumers as blockers.
pub fn Database::retention_plan(self : Database) -> Json raise {
  self.begin(false)
  defer self.rollback()
  self.verify_capture()
  let cursor = self.source_cursor()
  let floor = self.retention_floor()
  let consumers = self.query(
    "SELECT name,sequence,paused FROM _mooncdc_consumers ORDER BY sequence,name",
    [],
  )
  if consumers.is_empty() {
    self.commit()
    return {
      "allowed": false,
      "reason": "no consumers",
      "floor": floor.to_string(),
      "deletable": "0",
    }
  }
  let low = integer(consumers[0].values[1])
  @cdc.validate_cursor({ source: cursor.source, sequence: low, }, cursor, floor)
  let blockers : Array[Json] = []
  for row in consumers {
    if integer(row.values[1]) == low {
      blockers.push({
        "name": text(row.values[0]),
        "paused": integer(row.values[2]) != 0L,
      })
    }
  }
  let deletable = integer(
    self.scalar("SELECT count(*) FROM _mooncdc_events WHERE sequence<=?", [
      Integer(low),
    ]),
  )
  self.commit()
  {
    "allowed": true,
    "floor": floor.to_string(),
    "safe_through": low.to_string(),
    "deletable": deletable.to_string(),
    "blockers": Json::array(blockers),
  }
}

///|
/// Bound deletion work while preserving the minimum consumer cursor barrier.
pub fn Database::prune_bounded(
  self : Database,
  max_events : Int32,
) -> Int64 raise {
  if max_events <= 0 || max_events > 1000000 {
    raise StoreError("Invalid pruning batch size")
  }
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  let low = match
    self.scalar("SELECT min(sequence) FROM _mooncdc_consumers", []) {
    Integer(value) => value
    _ => raise StoreError("No consumers; refusing journal deletion")
  }
  let source = self.source_cursor()
  let floor = self.retention_floor()
  @cdc.validate_cursor({ source: source.source, sequence: low, }, source, floor)
  let sequences = self.query(
    "SELECT sequence FROM _mooncdc_events WHERE sequence>? AND sequence<=? ORDER BY sequence LIMIT ?",
    [Integer(floor), Integer(low), Integer(max_events.to_int64())],
    max_rows=max_events,
  )
  let mut next = floor
  for row in sequences {
    let sequence = integer(row.values[0])
    if next == 9223372036854775807L || sequence != next + 1L {
      raise StoreError("Refusing to prune a discontinuous journal")
    }
    next = sequence
  }
  if sequences.is_empty() && low > floor {
    raise StoreError("Acknowledged journal tail is missing")
  }
  let deleted = self.execute("DELETE FROM _mooncdc_events WHERE sequence<=?", [
    Integer(next),
  ])
  self.execute("UPDATE _mooncdc_meta SET floor=? WHERE singleton=1", [
    Integer(next),
  ])
  |> ignore
  self.commit()
  deleted
}

///|
/// Preview a target apply in a transaction that is ALWAYS rolled back.
/// This acquires a write lock; it is not a lock-free simulation.
pub fn Database::preview_batch(
  self : Database,
  batch : @cdc.Batch,
  plan~ : @cdc.ProjectionPlan? = None,
) -> Json raise {
  let batch = match plan {
    None => batch
    Some(plan) => plan.project_batch(batch)
  }
  batch.validate()
  self.begin(true)
  defer self.rollback()
  self.verify_projection()
  if self.projection_plan() != plan {
    raise StoreError("Preview plan differs from durable target plan")
  }
  let cursor = self.projection_cursor()
  if cursor.source != batch.start.source {
    raise StoreError("Preview source identity mismatch")
  }
  if cursor.sequence >= batch.end.sequence {
    return {
      "applicable": true,
      "already_applied": true,
      "events": 0,
      "cursor": cursor.to_wire(),
    }
  }
  if cursor != batch.start {
    raise StoreError("Preview batch does not start at target cursor")
  }
  let tables = self.projection_tables()
  let mut checked = 0
  for event in batch.events {
    let failure : String? = try {
      self.apply_event(@cdc.find_table(tables, event.table), event)
      None
    } catch {
      error => Some(error.to_string())
    }
    if failure is Some(message) {
      return {
        "applicable": false,
        "checked": checked,
        "sequence": event.sequence.to_string(),
        "table": event.table,
        "error": message,
      }
    }
    checked += 1
  }
  {
    "applicable": true,
    "already_applied": false,
    "events": checked,
    "start": cursor.to_wire(),
    "end": batch.end.to_wire(),
  }
}

///|
/// Remove only MoonCDC source objects, refusing active consumers or retained changes.
/// A source must be explicitly drained and consumers dropped first.
pub fn Database::uninstall_capture(
  self : Database,
  expected_source : String,
) -> Unit raise {
  self.begin(true)
  defer self.rollback()
  self.verify_capture()
  if self.source_cursor().source != expected_source {
    raise StoreError("Source identity confirmation mismatch")
  }
  if integer(self.scalar("SELECT count(*) FROM _mooncdc_consumers", [])) != 0L {
    raise StoreError("Drop consumers explicitly before uninstalling capture")
  }
  if integer(self.scalar("SELECT count(*) FROM _mooncdc_events", [])) != 0L {
    raise StoreError(
      "Uninstall refuses to discard retained events; drain and prune first",
    )
  }
  let tables = self.query("SELECT id FROM _mooncdc_tables ORDER BY id", [])
  for row in tables {
    let id = integer(row.values[0]).to_int()
    for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
      self.execute(
        "DROP TRIGGER " +
        @cdc.quote_identifier(@cdc.trigger_name(id, operation)),
        [],
      )
      |> ignore
    }
  }
  for
    name in [
      "_mooncdc_consumers", "_mooncdc_events", "_mooncdc_tables", "_mooncdc_meta",
    ] {
    self.execute("DROP TABLE " + @cdc.quote_identifier(name), []) |> ignore
  }
  self.commit()
}
