///|
pub fn Database::projection_plan(self : Database) -> @cdc.ProjectionPlan? raise {
  match
    self.scalar("SELECT plan_json FROM _mooncdc_projection WHERE singleton=1", []) {
    Null => None
    Text(value) => Some(@cdc.ProjectionPlan::from_wire(@cdc.parse_json(value)))
    _ => raise StoreError("Invalid projection plan metadata")
  }
}

///|
pub fn Database::initialize_filtered_projection(
  self : Database,
  snapshot : @cdc.Snapshot,
  plan : @cdc.ProjectionPlan,
) -> Unit raise {
  let projected = plan.project_snapshot(snapshot)
  self.initialize_projection_internal(projected, Some(plan))
}

///|
/// Accepts raw source events. The durable plan is checked in the apply transaction.
pub fn Database::apply_filtered_batch(
  self : Database,
  batch : @cdc.Batch,
  plan : @cdc.ProjectionPlan,
) -> Int32 raise {
  self.apply_batch_internal(plan.project_batch(batch), Some(plan))
}

///|
fn validate_plan_source(
  source : Database,
  plan : @cdc.ProjectionPlan,
) -> Unit raise {
  plan.validate()
  let schemas = source.capture_tables()
  for rule in plan.rules {
    if @cdc.find_table(schemas, rule.source.name) != rule.source {
      raise StoreError(
        "Projection rule does not match the captured source schema",
      )
    }
  }
}

///|
/// A plan is immutable for the lifetime of this target, even when only predicates change.
pub fn synchronize_filtered(
  source : Database,
  target : Database,
  consumer : String,
  plan : @cdc.ProjectionPlan,
  batch_limit~ : Int32 = 1000,
  max_batches~ : Int32 = 100,
) -> Int32 raise {
  if max_batches <= 0 || max_batches > 100000 {
    raise StoreError("Invalid synchronization batch budget")
  }
  source.verify_capture()
  target.verify_projection()
  validate_plan_source(source, plan)
  if target.projection_plan() != Some(plan) {
    raise StoreError("Stored projection plan differs from requested plan")
  }
  if target.projection_tables() != plan.rules.map(rule => rule.output_schema()) {
    raise StoreError("Filtered target schema differs from plan")
  }
  let mut applied = 0
  for _ in 0..<max_batches {
    let position = target.projection_cursor()
    let acknowledged = source.consumer_cursor(consumer)
    if acknowledged.source != position.source ||
      acknowledged.sequence > position.sequence {
      raise StoreError(
        "Consumer does not belong to this filtered target position",
      )
    }
    if acknowledged != position {
      source.acknowledge(consumer, acknowledged, position)
    }
    let raw = source.read_batch(position, limit=batch_limit)
    if raw.end == raw.start {
      break
    }
    applied += target.apply_filtered_batch(raw, plan)
    source.acknowledge(consumer, position, raw.end)
    if raw.end.sequence == raw.high_water {
      break
    }
  }
  applied
}

///|
pub fn audit_filtered_projection(
  source : Database,
  target : Database,
  plan : @cdc.ProjectionPlan,
  max_rows~ : Int32 = 100000,
  sample_limit~ : Int32 = 20,
) -> @cdc.AuditReport raise {
  if max_rows <= 0 || max_rows > 1000000 {
    raise StoreError("Invalid audit row budget")
  }
  source.begin(false)
  defer source.rollback()
  target.begin(false)
  defer target.rollback()
  source.verify_capture()
  target.verify_projection()
  validate_plan_source(source, plan)
  if target.projection_plan() != Some(plan) {
    raise StoreError("Audit plan differs from durable target plan")
  }
  let cursor = source.source_cursor()
  if target.projection_cursor() != cursor {
    raise StoreError("Catch up target before content audit")
  }
  let expected : Array[@cdc.TableSnapshot] = []
  let actual : Array[@cdc.TableSnapshot] = []
  let mut source_remaining = max_rows
  let mut target_remaining = max_rows
  for rule in plan.rules {
    let rows = source.query(
      rule.source.select_sql(),
      [],
      max_rows=source_remaining,
    )
    source_remaining -= rows.length()
    let schema = rule.output_schema()
    let projected : Array[@cdc.Row] = []
    for row in rows {
      if rule.project_row(row) is Some(value) {
        projected.push(value)
      }
    }
    let stored = target.query(
      schema.select_sql(),
      [],
      max_rows=target_remaining,
    )
    target_remaining -= stored.length()
    expected.push({ schema, rows: projected, })
    actual.push({ schema, rows: stored, })
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
