///|
pub fn Database::inspect_table(
  self : Database,
  name : String,
) -> @cdc.Table raise {
  @cdc.check_name(name)
  self.require_main_namespace(names=[name])
  self.definition(name, "table") |> ignore
  // Ask SQLite for the actual table kind: quoted names and string defaults may
  // contain "VIRTUAL TABLE" without declaring a virtual table.
  let kinds = self.query(
    "PRAGMA main.table_list(" + @cdc.quote_literal(name) + ")",
    [],
    max_rows=2,
  )
  if kinds.length() != 1 || text(kinds[0].values[2]) != "table" {
    raise StoreError("Virtual and shadow tables are not supported")
  }
  let rows = self.query(
    "PRAGMA table_xinfo(" + @cdc.quote_identifier(name) + ")",
    [],
    max_rows=129,
  )
  let columns : Array[@cdc.Column] = []
  for row in rows {
    if integer(row.values[6]) != 0L {
      raise StoreError("Generated and hidden columns are not supported")
    }
    let position = integer(row.values[5])
    if position > 128L {
      raise StoreError("Too many key columns")
    }
    columns.push({
      name: text(row.values[1]),
      declared_type: text(row.values[2]),
      required: integer(row.values[3]) != 0L,
      key_position: position.to_int(),
    })
  }
  let table = @cdc.Table::{ name, columns, }
  table.validate()
  let indexes = self.query(
    "PRAGMA index_list(" + @cdc.quote_identifier(name) + ")",
    [],
  )
  for index in indexes {
    if text(index.values[3]) == "pk" {
      let index_name = text(index.values[1])
      let terms = self.query(
        "PRAGMA index_xinfo(" + @cdc.quote_identifier(index_name) + ")",
        [],
      )
      for term in terms {
        if integer(term.values[5]) == 1L &&
          text(term.values[4]).to_upper() != "BINARY" {
          raise StoreError("Primary keys require BINARY collation")
        }
      }
    }
  }
  table
}

///|
pub fn Database::list_tables(self : Database) -> Array[String] raise {
  self
  .query(
    "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT GLOB '_mooncdc_*' ORDER BY name",
    [],
  )
  .map(row => text(row.values[0]))
}

///|
pub fn Database::source_cursor(self : Database) -> @cdc.Cursor raise {
  self.require_main_namespace()
  let rows = self.query(
    "SELECT format,source_id,floor FROM _mooncdc_meta WHERE singleton=1",
    [],
    max_rows=2,
  )
  if rows.length() != 1 || integer(rows[0].values[0]) != 1L {
    raise StoreError("Missing or unsupported capture metadata")
  }
  let floor = integer(rows[0].values[2])
  let sequence = integer(
    self.scalar(
      "SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='_mooncdc_events'),0)",
      [],
    ),
  )
  if floor < 0L || floor > sequence {
    raise StoreError("Invalid retention floor")
  }
  let cursor = @cdc.Cursor::{ source: text(rows[0].values[1]), sequence, }
  cursor.validate()
  cursor
}

///|
pub fn Database::retention_floor(self : Database) -> Int64 raise {
  self.require_main_namespace()
  integer(self.scalar("SELECT floor FROM _mooncdc_meta WHERE singleton=1", []))
}

///|
pub fn Database::capture_tables(self : Database) -> Array[@cdc.Table] raise {
  self.require_main_namespace()
  self
  .query("SELECT schema_json FROM _mooncdc_tables ORDER BY id", [])
  .map(row => @cdc.Table::from_wire(@cdc.parse_json(text(row.values[0]))))
}

///|
pub fn Database::verify_capture(self : Database) -> Unit raise {
  self.verify_capture_internal(false)
}

///|
fn Database::require_utf8(self : Database) -> Unit raise {
  if text(self.scalar("PRAGMA encoding", [])) != "UTF-8" {
    raise StoreError("Capture and projection databases require UTF-8 encoding")
  }
}

///|
fn Database::require_source_triggers(
  self : Database,
  name : String,
  allowed : Array[String],
) -> Unit raise {
  for
    row in self.query(
      "SELECT name FROM sqlite_schema WHERE type='trigger' AND tbl_name=?",
      [Text(name)],
    ) {
    if !allowed.contains(text(row.values[0])) {
      raise StoreError(
        "Additional source triggers are unsupported on " +
        name +
        "; remove them only after reviewing their business effects",
      )
    }
  }
}

///|
fn Database::verify_capture_internal(
  self : Database,
  allow_legacy : Bool,
) -> Unit raise {
  self.require_main_namespace()
  self.require_utf8()
  self.source_cursor() |> ignore
  let rows = self.query(
    "SELECT id,name,definition,schema_json FROM _mooncdc_tables ORDER BY id",
    [],
  )
  if rows.is_empty() {
    raise StoreError("No captured tables")
  }
  for row in rows {
    let id = integer(row.values[0])
    if id <= 0L || id > 2147483647L {
      raise StoreError("Capture table id out of range")
    }
    let name = text(row.values[1])
    if self.definition(name, "table") != text(row.values[2]) {
      raise StoreError(
        "Schema drift: " + name + "; reinitialize capture explicitly",
      )
    }
    let stored = @cdc.Table::from_wire(@cdc.parse_json(text(row.values[3])))
    if stored != self.inspect_table(name) {
      raise StoreError("Column metadata changed: " + name)
    }
    self.require_source_triggers(
      name,
      [@cdc.Insert, @cdc.Update, @cdc.Delete].map(op => {
        @cdc.trigger_name(id.to_int(), op)
      }),
    )
    for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
      let expected = stored.trigger_sql(id.to_int(), operation)
      let trigger = @cdc.trigger_name(id.to_int(), operation)
      let actual = self.definition(trigger, "trigger")
      if actual != expected {
        let legacy = stored.trigger_sql(
          id.to_int(),
          operation,
          legacy_v020=true,
        )
        let legacy_wide = stored.trigger_sql(
          id.to_int(),
          operation,
          legacy_v031=true,
        )
        if actual == legacy || actual == legacy_wide {
          if !allow_legacy {
            raise StoreError(
              "Capture requires upgrade-capture before consumption",
            )
          }
        } else {
          raise StoreError("Capture trigger changed: " + trigger)
        }
      }
    }
  }
}

///|
pub fn Database::install_capture(
  self : Database,
  names : Array[String],
) -> @cdc.Cursor raise {
  if names.is_empty() || names.length() > 128 {
    raise StoreError("Choose 1..128 tables")
  }
  self.begin(true)
  defer self.rollback()
  self.require_main_namespace(names~)
  self.require_utf8()
  let reserved = self.query(
    "SELECT name FROM sqlite_schema WHERE name GLOB '_mooncdc_*'",
    [],
  )
  if !reserved.is_empty() {
    raise StoreError(
      "Capture metadata already exists; install does not overwrite it",
    )
  }
  let seen : Map[String, Bool] = Map([])
  let tables : Array[@cdc.Table] = []
  for name in names {
    if seen.contains(name.to_lower()) {
      raise StoreError("Duplicate selected table: " + name)
    }
    seen[name.to_lower()] = true
    let table = self.inspect_table(name)
    self.require_source_triggers(name, [])
    let keys = table
      .key_indexes()
      .map(index => {
        @cdc.quote_identifier(table.columns[index].name) + " IS NULL"
      })
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
      raise StoreError("Existing NULL primary key: " + name)
    }
    tables.push(table)
  }
  for sql in @cdc.source_schema_sql() {
    self.execute(sql, []) |> ignore
  }
  self.execute(
    "INSERT INTO _mooncdc_meta VALUES (1,1,lower(hex(randomblob(16))),0)",
    [],
  )
  |> ignore
  for table in tables {
    self.execute(
      "INSERT INTO _mooncdc_tables(name,definition,schema_json) VALUES (?,?,?)",
      [
        Text(table.name),
        Text(self.definition(table.name, "table")),
        Text(table.signature()),
      ],
    )
    |> ignore
    let id = integer(
      self.scalar("SELECT id FROM _mooncdc_tables WHERE name=?", [
        Text(table.name),
      ]),
    )
    for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
      self.execute(table.trigger_sql(id.to_int(), operation), []) |> ignore
    }
  }
  let cursor = self.source_cursor()
  self.commit()
  cursor
}
