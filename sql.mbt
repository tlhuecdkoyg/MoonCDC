///|
/// Parameterized SQL plus exact SQLite values; identifiers are separately quoted.
pub(all) struct Statement {
  sql : String
  parameters : Array[Value]
} derive(Debug, Eq)

///|
pub fn Table::select_sql(self : Table) -> String raise CdcError {
  self.validate()
  let columns = self.columns.map(column => quote_identifier(column.name))
  let keys = self.key_indexes().map(index => columns[index])
  "SELECT " +
  columns.join(",") +
  " FROM " +
  quote_identifier(self.name) +
  " ORDER BY " +
  keys.join(",")
}

///|
pub fn Table::create_projection_sql(
  self : Table,
  target : String,
) -> String raise CdcError {
  self.validate()
  let columns = self.columns.map(column => {
    quote_identifier(column.name) +
    (if column.required || column.key_position > 0 { " NOT NULL" } else { "" })
  })
  let keys = self
    .key_indexes()
    .map(index => quote_identifier(self.columns[index].name))
  columns.push("PRIMARY KEY (" + keys.join(",") + ")")
  "CREATE TABLE " + quote_identifier(target) + " (" + columns.join(",") + ")"
}

///|
pub fn Table::insert_statement(
  self : Table,
  row : Row,
  target? : String,
) -> Statement raise CdcError {
  self.validate()
  row.validate(self)
  let target = target.unwrap_or(self.name)
  let columns = self.columns.map(column => quote_identifier(column.name))
  {
    sql: "INSERT INTO " +
    quote_identifier(target) +
    " (" +
    columns.join(",") +
    ") VALUES (" +
    self.columns.map(_ => "?").join(",") +
    ")",
    parameters: row.values.copy(),
  }
}

///|
pub fn Table::key_predicate(
  self : Table,
  row : Row,
) -> Statement raise CdcError {
  self.validate()
  row.validate(self)
  let terms : Array[String] = []
  let parameters : Array[Value] = []
  for index in self.key_indexes() {
    terms.push(quote_identifier(self.columns[index].name) + " IS ?")
    parameters.push(row.values[index])
  }
  { sql: terms.join(" AND "), parameters, }
}

///|
pub fn Table::lookup_statement(
  self : Table,
  row : Row,
  target? : String,
) -> Statement raise CdcError {
  let predicate = self.key_predicate(row)
  let columns = self.columns.map(column => quote_identifier(column.name))
  {
    sql: "SELECT " +
    columns.join(",") +
    " FROM " +
    quote_identifier(target.unwrap_or(self.name)) +
    " WHERE " +
    predicate.sql,
    parameters: predicate.parameters,
  }
}

///|
pub fn Table::delete_statement(
  self : Table,
  row : Row,
  target? : String,
) -> Statement raise CdcError {
  let predicate = self.key_predicate(row)
  {
    sql: "DELETE FROM " +
    quote_identifier(target.unwrap_or(self.name)) +
    " WHERE " +
    predicate.sql,
    parameters: predicate.parameters,
  }
}

///|
pub fn Table::update_statement(
  self : Table,
  before : Row,
  after : Row,
  target? : String,
) -> Statement raise CdcError {
  self.validate()
  after.validate(self)
  let predicate = self.key_predicate(before)
  let assignments = self.columns.map(column => {
    quote_identifier(column.name) + "=?"
  })
  let parameters = after.values.copy()
  for value in predicate.parameters {
    parameters.push(value)
  }
  {
    sql: "UPDATE " +
    quote_identifier(target.unwrap_or(self.name)) +
    " SET " +
    assignments.join(",") +
    " WHERE " +
    predicate.sql,
    parameters,
  }
}

///|
fn sqlite_wire_value(expression : String) -> String {
  "CASE typeof(" +
  expression +
  ") " +
  "WHEN 'null' THEN json_array('null') " +
  "WHEN 'integer' THEN json_array('integer',CAST(" +
  expression +
  " AS TEXT)) " +
  "WHEN 'real' THEN json_array('real'," +
  expression +
  ") " +
  "WHEN 'text' THEN json_array('text'," +
  expression +
  ") " +
  "WHEN 'blob' THEN json_array('blob',hex(" +
  expression +
  ")) END"
}

///|
pub fn Table::row_expression(
  self : Table,
  prefix : String,
) -> String raise CdcError {
  self.validate()
  if prefix != "NEW" && prefix != "OLD" {
    raise Invalid("Trigger row prefix must be NEW or OLD")
  }
  let parts = self.columns.map(column => {
    "json(" +
    sqlite_wire_value(prefix + "." + quote_identifier(column.name)) +
    ")"
  })
  "json_array(" + parts.join(",") + ")"
}

///|
pub fn trigger_name(
  table_id : Int32,
  operation : Operation,
) -> String raise CdcError {
  if table_id <= 0 {
    raise Invalid("Capture table id must be positive")
  }
  "_mooncdc_t" + table_id.to_string() + "_" + operation.name()
}

///|
pub fn Table::trigger_sql(
  self : Table,
  table_id : Int32,
  operation : Operation,
) -> String raise CdcError {
  self.validate()
  let name = trigger_name(table_id, operation)
  let before = if operation == Insert {
    "NULL"
  } else {
    self.row_expression("OLD")
  }
  let after = if operation == Delete {
    "NULL"
  } else {
    self.row_expression("NEW")
  }
  let key_checks : Array[String] = []
  if operation != Delete {
    for index in self.key_indexes() {
      key_checks.push(
        "NEW." + quote_identifier(self.columns[index].name) + " IS NULL",
      )
    }
  }
  let key_guard = if key_checks.is_empty() {
    ""
  } else {
    "SELECT RAISE(ABORT,'MoonCDC: NULL primary key') WHERE " +
    key_checks.join(" OR ") +
    "; "
  }
  "CREATE TRIGGER " +
  quote_identifier(name) +
  " AFTER " +
  operation.name().to_upper() +
  " ON " +
  quote_identifier(self.name) +
  " BEGIN " +
  key_guard +
  "INSERT INTO _mooncdc_events(table_name,operation,before_row,after_row) VALUES (" +
  quote_literal(self.name) +
  "," +
  quote_literal(operation.name()) +
  "," +
  before +
  "," +
  after +
  "); END"
}

///|
pub fn source_schema_sql() -> Array[String] {
  [
    "CREATE TABLE _mooncdc_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1),format INTEGER NOT NULL,source_id TEXT NOT NULL,floor INTEGER NOT NULL CHECK(floor>=0))",
    "CREATE TABLE _mooncdc_tables(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL UNIQUE,definition TEXT NOT NULL,schema_json TEXT NOT NULL)",
    "CREATE TABLE _mooncdc_events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,table_name TEXT NOT NULL,operation TEXT NOT NULL CHECK(operation IN ('insert','update','delete')),before_row TEXT,after_row TEXT)",
    "CREATE INDEX _mooncdc_event_table ON _mooncdc_events(table_name,sequence)",
    "CREATE TABLE _mooncdc_consumers(name TEXT PRIMARY KEY NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0),paused INTEGER NOT NULL DEFAULT 0 CHECK(paused IN (0,1)))",
  ]
}

///|
pub fn target_schema_sql() -> Array[String] {
  [
    "CREATE TABLE _mooncdc_projection(singleton INTEGER PRIMARY KEY CHECK(singleton=1),format INTEGER NOT NULL,source_id TEXT NOT NULL,sequence INTEGER NOT NULL CHECK(sequence>=0),schema_json TEXT NOT NULL)",
  ]
}
