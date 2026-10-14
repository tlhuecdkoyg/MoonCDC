///|
pub suberror StoreError {
  StoreError(String)
}

///|
pub struct Database {
  connection : @sqlite3.Connection
  mut closed : Bool
}

///|
pub fn Database::open(path : String) -> Database raise {
  let connection = @sqlite3.Connection::open(path)
  let db = Database::{ connection, closed: false, }
  errdefer (connection.close() catch { _ => () })
  db.execute("PRAGMA busy_timeout=5000", []) |> ignore
  db.execute("PRAGMA foreign_keys=ON", []) |> ignore
  db.execute("PRAGMA recursive_triggers=ON", []) |> ignore
  db.execute("PRAGMA synchronous=FULL", []) |> ignore
  db
}

///|
pub fn Database::close(self : Database) -> Unit raise {
  if !self.closed {
    self.connection.close()
    self.closed = true
  }
}

///|
fn Database::ensure_open(self : Database) -> Unit raise StoreError {
  if self.closed {
    raise StoreError("Database is closed")
  }
}

///|
fn to_sqlite(value : @cdc.Value) -> @sqlite3.Value {
  match value {
    Null => Null
    Integer(v) => Integer(v)
    Real(v) => Real(v)
    Text(v) => Text(v)
    Blob(v) => Blob(v)
  }
}

///|
fn from_sqlite(value : @sqlite3.Value) -> @cdc.Value {
  match value {
    Null => Null
    Integer(v) => Integer(v)
    Real(v) => Real(v)
    Text(v) => Text(v)
    Blob(v) => Blob(v)
  }
}

///|
fn Database::prepare(
  self : Database,
  sql : String,
  values : Array[@cdc.Value],
) -> @sqlite3.Statement raise {
  self.ensure_open()
  let statement = self.connection.prepare(sql)
  errdefer (statement.finalize() catch { _ => () })
  for index, value in values {
    value.validate()
    statement.bind(index=index + 1, to_sqlite(value))
  }
  statement
}

///|
pub fn Database::execute(
  self : Database,
  sql : String,
  values : Array[@cdc.Value],
) -> Int64 raise {
  let statement = self.prepare(sql, values)
  defer (statement.finalize() catch { _ => () })
  while statement.step() {
    ()
  }
  self.connection.changes()
}

///|
pub fn Database::query(
  self : Database,
  sql : String,
  values : Array[@cdc.Value],
  max_rows~ : Int32 = 100000,
) -> Array[@cdc.Row] raise {
  if max_rows < 0 {
    raise StoreError("Negative query row limit")
  }
  let statement = self.prepare(sql, values)
  defer (statement.finalize() catch { _ => () })
  let result : Array[@cdc.Row] = []
  let width = statement.column_count()
  while statement.step() {
    if result.length() >= max_rows {
      raise StoreError("Query exceeded row limit")
    }
    let cells : Array[@cdc.Value] = []
    for index in 0..<width {
      let value : @sqlite3.Value = statement.column(index~)
      cells.push(from_sqlite(value))
    }
    result.push({ values: cells, })
  }
  result
}

///|
fn Database::scalar(
  self : Database,
  sql : String,
  values : Array[@cdc.Value],
) -> @cdc.Value raise {
  let rows = self.query(sql, values, max_rows=2)
  if rows.length() != 1 || rows[0].values.length() != 1 {
    raise StoreError("Expected one scalar result")
  }
  rows[0].values[0]
}

///|
fn text(value : @cdc.Value) -> String raise StoreError {
  match value {
    Text(v) => v
    _ => raise StoreError("Expected TEXT in metadata")
  }
}

///|
fn integer(value : @cdc.Value) -> Int64 raise StoreError {
  match value {
    Integer(v) => v
    _ => raise StoreError("Expected INTEGER in metadata")
  }
}

///|
fn Database::begin(self : Database, write : Bool) -> Unit raise {
  self.execute(if write { "BEGIN IMMEDIATE" } else { "BEGIN" }, []) |> ignore
}

///|
fn Database::commit(self : Database) -> Unit raise {
  self.execute("COMMIT", []) |> ignore
}

///|
fn Database::rollback(self : Database) -> Unit {
  try self.execute("ROLLBACK", []) |> ignore catch {
    _ => ()
  }
}

///|
pub fn Database::has_object(self : Database, name : String) -> Bool raise {
  !self
  .query(
    "SELECT name FROM sqlite_schema WHERE name=? COLLATE NOCASE",
    [Text(name)],
    max_rows=2,
  )
  .is_empty()
}

///|
fn Database::definition(
  self : Database,
  name : String,
  kind : String,
) -> String raise {
  let rows = self.query(
    "SELECT sql FROM sqlite_schema WHERE name=? AND type=?",
    [Text(name), Text(kind)],
    max_rows=2,
  )
  if rows.length() != 1 {
    raise StoreError("Missing " + kind + ": " + name)
  }
  text(rows[0].values[0])
}
