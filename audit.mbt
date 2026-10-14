///|
pub(all) struct RowDifference {
  table : String
  key : String
  kind : String
  columns : Array[String]
} derive(Debug, Eq)

///|
pub(all) struct TableAudit {
  table : String
  expected_rows : Int32
  actual_rows : Int32
  missing : Int32
  unexpected : Int32
  changed : Int32
  samples : Array[RowDifference]
} derive(Debug, Eq)

///|
pub(all) struct AuditReport {
  cursor : Cursor
  tables : Array[TableAudit]
} derive(Debug, Eq)

///|
pub fn TableAudit::consistent(self : TableAudit) -> Bool {
  self.missing == 0 && self.unexpected == 0 && self.changed == 0
}

///|
pub fn AuditReport::consistent(self : AuditReport) -> Bool {
  for table in self.tables {
    if !table.consistent() {
      return false
    }
  }
  true
}

///|
fn index_rows(table : TableSnapshot) -> Map[String, Row] raise CdcError {
  let indexed : Map[String, Row] = Map([])
  for row in table.rows {
    let key = row.key(table.schema)
    if indexed.contains(key) {
      raise Invalid("Duplicate row identity in audit input")
    }
    indexed[key] = row
  }
  indexed
}

///|
pub fn compare_table(
  expected : TableSnapshot,
  actual : TableSnapshot,
  sample_limit~ : Int32 = 20,
) -> TableAudit raise CdcError {
  if expected.schema != actual.schema {
    raise Conflict("Cannot compare different table schemas")
  }
  if sample_limit < 0 || sample_limit > 10000 {
    raise Invalid("Invalid audit sample limit")
  }
  let left = index_rows(expected)
  let right = index_rows(actual)
  let samples : Array[RowDifference] = []
  let mut missing = 0
  let mut unexpected = 0
  let mut changed = 0
  // Preserve the caller's stable row ordering in diagnostic samples.
  for row in expected.rows {
    let key = row.key(expected.schema)
    match right.get(key) {
      None => {
        missing += 1
        if samples.length() < sample_limit {
          samples.push({
            table: expected.schema.name,
            key,
            kind: "missing",
            columns: [],
          })
        }
      }
      Some(other) =>
        if other != row {
          changed += 1
          let columns : Array[String] = []
          for index, value in row.values {
            if value != other.values[index] {
              columns.push(expected.schema.columns[index].name)
            }
          }
          if samples.length() < sample_limit {
            samples.push({
              table: expected.schema.name,
              key,
              kind: "changed",
              columns,
            })
          }
        }
    }
  }
  for row in actual.rows {
    let key = row.key(actual.schema)
    if !left.contains(key) {
      unexpected += 1
      if samples.length() < sample_limit {
        samples.push({
          table: expected.schema.name,
          key,
          kind: "unexpected",
          columns: [],
        })
      }
    }
  }
  {
    table: expected.schema.name,
    expected_rows: expected.rows.length(),
    actual_rows: actual.rows.length(),
    missing,
    unexpected,
    changed,
    samples,
  }
}

///|
pub fn compare_snapshots(
  expected : Snapshot,
  actual : Snapshot,
  sample_limit~ : Int32 = 20,
) -> AuditReport raise CdcError {
  expected.validate()
  actual.validate()
  if expected.cursor != actual.cursor {
    raise Conflict("Audit snapshots are at different source positions")
  }
  if expected.schemas() != actual.schemas() {
    raise Conflict("Audit snapshot schemas differ")
  }
  let tables : Array[TableAudit] = []
  for index, table in expected.tables {
    tables.push(compare_table(table, actual.tables[index], sample_limit~))
  }
  { cursor: expected.cursor, tables, }
}

///|
pub fn RowDifference::to_wire(self : RowDifference) -> Json {
  {
    "table": self.table,
    "key": self.key,
    "kind": self.kind,
    "columns": Json::array(self.columns.map(Json::string)),
  }
}

///|
pub fn TableAudit::to_wire(self : TableAudit) -> Json {
  {
    "table": self.table,
    "consistent": self.consistent(),
    "expected_rows": self.expected_rows,
    "actual_rows": self.actual_rows,
    "missing": self.missing,
    "unexpected": self.unexpected,
    "changed": self.changed,
    "samples": Json::array(self.samples.map(sample => sample.to_wire())),
  }
}

///|
pub fn AuditReport::to_wire(self : AuditReport) -> Json {
  {
    "format": "mooncdc.audit.v1",
    "consistent": self.consistent(),
    "cursor": self.cursor.to_wire(),
    "tables": Json::array(self.tables.map(table => table.to_wire())),
  }
}
