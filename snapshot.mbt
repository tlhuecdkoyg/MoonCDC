///|
pub(all) struct TableSnapshot {
  schema : Table
  rows : Array[Row]
} derive(Debug, Eq)

///|
pub(all) struct Snapshot {
  cursor : Cursor
  tables : Array[TableSnapshot]
} derive(Debug, Eq)

///|
pub fn Snapshot::validate(self : Snapshot) -> Unit raise CdcError {
  self.cursor.validate()
  if self.tables.is_empty() || self.tables.length() > 128 {
    raise Invalid("Snapshot must contain 1..128 tables")
  }
  let names : Map[String, Bool] = Map([])
  for table in self.tables {
    table.schema.validate()
    if names.contains(table.schema.name.to_lower()) {
      raise Invalid("Duplicate snapshot table")
    }
    names[table.schema.name.to_lower()] = true
    let keys : Map[String, Bool] = Map([])
    for row in table.rows {
      let key = row.key(table.schema)
      if keys.contains(key) {
        raise Invalid("Duplicate snapshot key in " + table.schema.name)
      }
      keys[key] = true
    }
  }
}

///|
pub fn Snapshot::row_count(self : Snapshot) -> Int32 {
  let mut count = 0
  for table in self.tables {
    count += table.rows.length()
  }
  count
}

///|
pub fn Snapshot::schemas(self : Snapshot) -> Array[Table] {
  self.tables.map(table => table.schema)
}

///|
pub fn Snapshot::to_wire(self : Snapshot) -> Json raise CdcError {
  self.validate()
  let tables : Array[Json] = self.tables.map(table => {
    "schema": table.schema.to_wire(),
    "rows": Json::array(table.rows.map(row => row.to_wire())),
  })
  {
    "format": "mooncdc.snapshot.v1",
    "cursor": self.cursor.to_wire(),
    "tables": Json::array(tables),
  }
}

///|
pub fn Snapshot::from_wire(value : Json) -> Snapshot raise CdcError {
  if string_field(value, "format") != "mooncdc.snapshot.v1" {
    raise Invalid("Unsupported snapshot format")
  }
  let tables = array_field(value, "tables").map(table => TableSnapshot::{
    schema: Table::from_wire(field(table, "schema")),
    rows: array_field(table, "rows").map(row => Row::from_wire(row)),
  })
  let snapshot = Snapshot::{
    cursor: Cursor::from_wire(field(value, "cursor")),
    tables,
  }
  snapshot.validate()
  snapshot
}

///|
pub fn schemas_to_wire(tables : Array[Table]) -> String {
  Json::array(tables.map(table => table.to_wire())).stringify()
}

///|
pub fn schemas_from_wire(text : String) -> Array[Table] raise CdcError {
  match parse_json(text) {
    Array(tables) => tables.map(table => Table::from_wire(table))
    _ => raise Invalid("Expected schema array")
  }
}

///|
pub fn find_table(tables : Array[Table], name : String) -> Table raise CdcError {
  for table in tables {
    if table.name == name {
      return table
    }
  }
  raise Corrupt("Event references uncaptured table: " + name)
}

///|
pub fn validate_cursor(
  cursor : Cursor,
  source : Cursor,
  floor : Int64,
) -> Unit raise CdcError {
  cursor.validate()
  source.validate()
  if cursor.source != source.source {
    raise Conflict("Cursor belongs to another source")
  }
  if cursor.sequence < floor {
    raise Stale("Cursor precedes retained history; initialize a new snapshot")
  }
  if cursor.sequence > source.sequence {
    raise Invalid("Cursor is ahead of source")
  }
}
