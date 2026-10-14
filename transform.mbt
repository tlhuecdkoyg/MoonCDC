///|
pub(all) struct ColumnSelection {
  source : String
  target : String
} derive(Debug, Eq)

///|
pub(all) struct TableRule {
  source : Table
  target : String
  columns : Array[ColumnSelection]
  filter : Predicate
} derive(Debug, Eq)

///|
pub(all) struct ProjectionPlan {
  rules : Array[TableRule]
} derive(Debug, Eq)

///|
pub fn TableRule::output_schema(self : TableRule) -> Table raise CdcError {
  self.source.validate()
  self.filter.validate(self.source)
  let columns : Array[Column] = []
  let selected : Map[String, Bool] = Map([])
  for selection in self.columns {
    if selected.contains(selection.source) {
      raise Invalid("Duplicate selected source column")
    }
    selected[selection.source] = true
    let original = self.source.columns[require_column(
        self.source,
        selection.source,
      )]
    columns.push({ ..original, name: selection.target, })
  }
  for key in self.source.key_indexes() {
    if !selected.contains(self.source.columns[key].name) {
      raise Invalid("Projection must retain all primary key columns")
    }
  }
  let table = Table::{ name: self.target, columns, }
  table.validate()
  table
}

///|
pub fn TableRule::project_row(
  self : TableRule,
  row : Row,
) -> Row? raise CdcError {
  self.output_schema() |> ignore
  if !self.filter.matches(self.source, row) {
    return None
  }
  Some({
    values: self.columns.map(column => {
      row.values[require_column(self.source, column.source)]
    }),
  })
}

///|
pub fn TableRule::project_event(
  self : TableRule,
  event : Event,
) -> Event? raise CdcError {
  event.validate()
  if event.table != self.source.name {
    raise Invalid("Rule applied to the wrong source table")
  }
  let before = match event.before {
    Some(row) => self.project_row(row)
    None => None
  }
  let after = match event.after {
    Some(row) => self.project_row(row)
    None => None
  }
  match (before, after) {
    (None, None) => None
    (None, Some(_)) =>
      Some({ ..event, table: self.target, operation: Insert, before, after, })
    (Some(_), None) =>
      Some({ ..event, table: self.target, operation: Delete, before, after, })
    (Some(left), Some(right)) =>
      if left == right {
        None
      } else {
        Some({ ..event, table: self.target, operation: Update, before, after, })
      }
  }
}

///|
pub fn ProjectionPlan::validate(self : ProjectionPlan) -> Unit raise CdcError {
  if self.rules.is_empty() || self.rules.length() > 128 {
    raise Invalid("Projection needs 1..128 rules")
  }
  let sources : Map[String, Bool] = Map([])
  let targets : Map[String, Bool] = Map([])
  for rule in self.rules {
    rule.output_schema() |> ignore
    if sources.contains(rule.source.name.to_lower()) ||
      targets.contains(rule.target.to_lower()) {
      raise Invalid("Projection source and target names must be unique")
    }
    sources[rule.source.name.to_lower()] = true
    targets[rule.target.to_lower()] = true
  }
}

///|
pub fn ProjectionPlan::project_snapshot(
  self : ProjectionPlan,
  snapshot : Snapshot,
) -> Snapshot raise CdcError {
  self.validate()
  snapshot.validate()
  let tables : Array[TableSnapshot] = []
  for rule in self.rules {
    let mut found = false
    for table in snapshot.tables {
      if table.schema.name == rule.source.name {
        if table.schema != rule.source {
          raise Conflict("Projection rule schema does not match snapshot")
        }
        let rows : Array[Row] = []
        for row in table.rows {
          if rule.project_row(row) is Some(projected) {
            rows.push(projected)
          }
        }
        tables.push({ schema: rule.output_schema(), rows, })
        found = true
      }
    }
    if !found {
      raise Invalid("Projection source table is absent from snapshot")
    }
  }
  { cursor: snapshot.cursor, tables, }
}

///|
/// Cursor intervals survive filtering, including batches containing no output rows.
pub fn ProjectionPlan::project_batch(
  self : ProjectionPlan,
  batch : Batch,
) -> Batch raise CdcError {
  self.validate()
  batch.validate()
  let events : Array[Event] = []
  for event in batch.events {
    for rule in self.rules {
      if event.table == rule.source.name {
        if rule.project_event(event) is Some(projected) {
          events.push(projected)
        }
        break
      }
    }
  }
  { ..batch, events, }
}

///|
pub fn ProjectionPlan::to_wire(self : ProjectionPlan) -> Json raise CdcError {
  self.validate()
  let rules : Array[Json] = self.rules.map(rule => {
    let columns : Array[Json] = rule.columns.map(column => {
      "source": column.source,
      "target": column.target,
    })
    {
      "source": rule.source.to_wire(),
      "target": rule.target,
      "columns": Json::array(columns),
      "filter": rule.filter.to_wire(),
    }
  })
  { "format": "mooncdc.projection.v1", "rules": Json::array(rules) }
}

///|
pub fn ProjectionPlan::from_wire(value : Json) -> ProjectionPlan raise CdcError {
  if string_field(value, "format") != "mooncdc.projection.v1" {
    raise Invalid("Unsupported projection plan format")
  }
  let rules = array_field(value, "rules").map(rule => TableRule::{
    source: Table::from_wire(field(rule, "source")),
    target: string_field(rule, "target"),
    columns: array_field(rule, "columns").map(column => ColumnSelection::{
      source: string_field(column, "source"),
      target: string_field(column, "target"),
    }),
    filter: Predicate::from_wire(field(rule, "filter")),
  })
  let plan = ProjectionPlan::{ rules, }
  plan.validate()
  plan
}
