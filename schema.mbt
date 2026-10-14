///|
pub(all) struct Column {
  name : String
  declared_type : String
  required : Bool
  key_position : Int32
} derive(Debug, Eq)

///|
pub(all) struct Table {
  name : String
  columns : Array[Column]
} derive(Debug, Eq)

///|
pub(all) struct Row {
  values : Array[Value]
} derive(Debug, Eq)

///|
pub fn check_name(name : String) -> Unit raise CdcError {
  if name.is_empty() || name.length() > 255 || name.contains("\u0000") {
    raise Invalid("Names must contain 1..255 non-NUL code units")
  }
}

///|
pub fn quote_identifier(name : String) -> String raise CdcError {
  check_name(name)
  "\"" + name.replace_all(old="\"", new="\"\"") + "\""
}

///|
pub fn quote_literal(text : String) -> String raise CdcError {
  if text.contains("\u0000") {
    raise Invalid("NUL is not allowed in SQL literals")
  }
  "'" + text.replace_all(old="'", new="''") + "'"
}

///|
pub fn Table::validate(self : Table) -> Unit raise CdcError {
  check_name(self.name)
  let lower = self.name.to_lower()
  if lower.has_prefix("sqlite_") || lower.has_prefix("_mooncdc_") {
    raise Invalid("Reserved table name: " + self.name)
  }
  if self.columns.is_empty() || self.columns.length() > 128 {
    raise Invalid("Capture supports 1..128 columns")
  }
  let names : Map[String, Bool] = Map([])
  let positions : Map[Int32, Bool] = Map([])
  let mut keys = 0
  for column in self.columns {
    check_name(column.name)
    let name = column.name.to_lower()
    if names.contains(name) {
      raise Invalid("Duplicate column: " + column.name)
    }
    names[name] = true
    if column.key_position < 0 {
      raise Invalid("Negative primary key position")
    }
    if column.key_position > 0 {
      if positions.contains(column.key_position) {
        raise Invalid("Duplicate primary key position")
      }
      positions[column.key_position] = true
      keys += 1
    }
  }
  if keys == 0 {
    raise Invalid("Explicit primary key required")
  }
  for position in 1..<=keys {
    if !positions.contains(position) {
      raise Invalid("Primary key positions must be contiguous")
    }
  }
}

///|
pub fn Table::key_indexes(self : Table) -> Array[Int32] {
  let result : Array[Int32] = []
  for position in 1..<=self.columns.length() {
    for index, column in self.columns {
      if column.key_position == position {
        result.push(index)
      }
    }
  }
  result
}

///|
pub fn Table::column_index(self : Table, name : String) -> Int32? {
  for index, column in self.columns {
    if column.name == name {
      return Some(index)
    }
  }
  None
}

///|
pub fn Row::validate(self : Row, table : Table) -> Unit raise CdcError {
  if self.values.length() != table.columns.length() {
    raise Invalid("Row width differs from schema for " + table.name)
  }
  for index, value in self.values {
    value.validate()
    let column = table.columns[index]
    if value == Null && (column.required || column.key_position > 0) {
      raise Invalid("NULL in required/key column: " + column.name)
    }
  }
}

///|
pub fn Row::key(self : Row, table : Table) -> String raise CdcError {
  self.validate(table)
  let parts : Array[Json] = []
  for index in table.key_indexes() {
    parts.push(self.values[index].to_wire())
  }
  Json::array(parts).stringify()
}

///|
pub fn Row::to_wire(self : Row) -> Json raise CdcError {
  Json::array(self.values.map(value => value.to_wire()))
}

///|
pub fn Row::from_wire(value : Json) -> Row raise CdcError {
  match value {
    Array(values) => { values: values.map(value => Value::from_wire(value)), }
    _ => raise Invalid("Expected row array")
  }
}

///|
pub fn Column::to_wire(self : Column) -> Json {
  {
    "name": self.name,
    "type": self.declared_type,
    "required": self.required,
    "key_position": self.key_position.to_string(),
  }
}

///|
pub fn Table::to_wire(self : Table) -> Json {
  {
    "name": self.name,
    "columns": Json::array(self.columns.map(column => column.to_wire())),
  }
}

///|
pub fn Table::from_wire(value : Json) -> Table raise CdcError {
  let columns = array_field(value, "columns").map(column => {
    let position = integer_field(column, "key_position")
    if position < 0L || position > 128L {
      raise Invalid("Invalid key position")
    }
    Column::{
      name: string_field(column, "name"),
      declared_type: string_field(column, "type"),
      required: boolean_field(column, "required"),
      key_position: position.to_int(),
    }
  })
  let table = Table::{ name: string_field(value, "name"), columns, }
  table.validate()
  table
}

///|
pub fn Table::signature(self : Table) -> String {
  self.to_wire().stringify()
}
