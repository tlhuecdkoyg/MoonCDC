///|
pub fn Database::projection_status(self : Database) -> Json raise {
  self.begin(false)
  defer self.rollback()
  self.verify_projection()
  let cursor = self.projection_cursor()
  let plan = self.projection_plan()
  let tables : Array[Json] = []
  for table in self.projection_tables() {
    let count = integer(
      self.scalar("SELECT count(*) FROM " + @cdc.quote_identifier(table.name), []),
    )
    tables.push({ "schema": table.to_wire(), "rows": count.to_string() })
  }
  self.commit()
  {
    "format": "mooncdc.projection-status.v1",
    "cursor": cursor.to_wire(),
    "filtered": plan is Some(_),
    "plan": match plan {
      None => Json::null()
      Some(plan) => plan.to_wire()
    },
    "tables": Json::array(tables),
  }
}

///|
/// Explain recovery position without modifying either database.
pub fn synchronization_status(
  source : Database,
  target : Database,
  consumer : String,
) -> Json raise {
  source.begin(false)
  defer source.rollback()
  target.begin(false)
  defer target.rollback()
  source.verify_capture()
  target.verify_projection()
  let high = source.source_cursor()
  let floor = source.retention_floor()
  let position = target.projection_cursor()
  let acknowledged = source.consumer_cursor(consumer)
  let compatible = position.source == high.source &&
    position.sequence >= floor &&
    position.sequence <= high.sequence &&
    acknowledged.sequence <= position.sequence
  let state = if !compatible {
    "reinitialize"
  } else if acknowledged.sequence < position.sequence {
    "repair_acknowledgement"
  } else if position.sequence < high.sequence {
    "catch_up"
  } else {
    "caught_up"
  }
  let report : Json = {
    "state": state,
    "consumer": consumer,
    "source": high.to_wire(),
    "target": position.to_wire(),
    "acknowledged": acknowledged.to_wire(),
    "floor": floor.to_string(),
    "resume_position_valid": compatible,
    "schema_validation_still_required": true,
    "sequence_distance": if position.source == high.source {
      Json::string((high.sequence - position.sequence).to_string())
    } else {
      Json::null()
    },
  }
  target.commit()
  source.commit()
  report
}

///|
/// Collect actionable failures without changing capture metadata or repairing data.
/// Unlike verify_capture, this reports multiple problems in one pass.
pub fn Database::diagnose(
  self : Database,
  check_storage~ : Bool = false,
) -> Json raise {
  self.begin(false)
  defer self.rollback()
  let issues : Array[Json] = []
  let details : Array[Json] = []
  let mut source : @cdc.Cursor? = None
  try {
    source = Some(self.source_cursor())
  } catch {
    error =>
      issues.push({
        "component": "source_metadata",
        "error": error.to_string(),
        "action": "Restore intact metadata or initialize a new capture; do not guess a cursor.",
      })
  }
  let tables = self.capture_tables() catch {
    error => {
      issues.push({
        "component": "schema_manifest",
        "error": error.to_string(),
        "action": "Restore the manifest from a trusted backup.",
      })
      []
    }
  }
  for table in tables {
    let detail : Json = try {
      let actual = self.inspect_table(table.name)
      let difference = @cdc.compare_schemas([table], [actual])
      if actual != table {
        issues.push({
          "component": "table_schema",
          "table": table.name,
          "error": "Schema differs from capture manifest",
          "action": "Reinitialize capture and projections after planned DDL changes.",
        })
      }
      let metadata = self.query(
        "SELECT id,definition FROM _mooncdc_tables WHERE name=?",
        [Text(table.name)],
        max_rows=2,
      )
      if metadata.length() != 1 {
        raise StoreError("Table metadata is missing or duplicated")
      }
      let id = integer(metadata[0].values[0]).to_int()
      if text(metadata[0].values[1]) != self.definition(table.name, "table") {
        issues.push({
          "component": "table_ddl",
          "table": table.name,
          "error": "Original CREATE TABLE statement changed",
          "action": "Reinitialize instead of editing the stored definition.",
        })
      }
      for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
        let name = @cdc.trigger_name(id, operation)
        try {
          if self.definition(name, "trigger") !=
            table.trigger_sql(id, operation) {
            raise StoreError(
              "Trigger SQL differs from expected capture contract",
            )
          }
        } catch {
          error =>
            issues.push({
              "component": "trigger",
              "name": name,
              "error": error.to_string(),
              "action": "Stop consumers and reinitialize; recreating a trigger cannot recover missed writes.",
            })
        }
      }
      { "table": table.name, "schema_comparison": difference }
    } catch {
      error => {
        issues.push({
          "component": "table",
          "table": table.name,
          "error": error.to_string(),
          "action": "Restore the table or start a new capture generation.",
        })
        { "table": table.name, "available": false }
      }
    }
    details.push(detail)
  }
  if source is Some(cursor) {
    try {
      let floor = self.retention_floor()
      let count = integer(
        self.scalar("SELECT count(*) FROM _mooncdc_events", []),
      )
      if count != cursor.sequence - floor {
        issues.push({
          "component": "journal",
          "error": "Retained count differs from cursor interval",
          "action": "Run verify; do not acknowledge beyond missing events.",
        })
      }
      for
        row in self.query(
          "SELECT name,sequence FROM _mooncdc_consumers ORDER BY name",
          [],
        ) {
        let sequence = integer(row.values[1])
        if sequence < floor || sequence > cursor.sequence {
          issues.push({
            "component": "consumer",
            "name": text(row.values[0]),
            "error": "Consumer is outside the retained source interval",
            "action": "Initialize a new consumer and target from a consistent snapshot.",
          })
        }
      }
    } catch {
      error =>
        issues.push({
          "component": "journal_metadata",
          "error": error.to_string(),
          "action": "Restore consistent source metadata from backup.",
        })
    }
  }
  if check_storage {
    for row in self.query("PRAGMA quick_check(20)", [], max_rows=20) {
      let message = text(row.values[0])
      if message != "ok" {
        issues.push({
          "component": "sqlite_storage",
          "error": message,
          "action": "Use SQLite recovery or restore a backup before consuming changes.",
        })
      }
    }
  }
  self.commit()
  {
    "format": "mooncdc.diagnostics.v1",
    "healthy": issues.is_empty(),
    "storage_checked": check_storage,
    "issues": Json::array(issues),
    "tables": Json::array(details),
  }
}
