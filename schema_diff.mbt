///|
/// Explain schema incompatibilities without attempting an unsafe automatic migration.
pub fn compare_schemas(
  expected : Array[Table],
  actual : Array[Table],
) -> Json raise CdcError {
  let issues : Array[Json] = []
  let wanted : Map[String, Table] = Map([])
  let observed : Map[String, Table] = Map([])
  for table in expected {
    table.validate()
    if wanted.contains(table.name) {
      raise Invalid("Duplicate expected schema")
    }
    wanted[table.name] = table
  }
  for table in actual {
    table.validate()
    if observed.contains(table.name) {
      raise Invalid("Duplicate actual schema")
    }
    observed[table.name] = table
  }
  for table in expected {
    match observed.get(table.name) {
      None => issues.push({ "table": table.name, "kind": "missing_table" })
      Some(other) => {
        let before : Map[String, Column] = Map([])
        let after : Map[String, Column] = Map([])
        for column in table.columns {
          before[column.name] = column
        }
        for column in other.columns {
          after[column.name] = column
        }
        for index, column in table.columns {
          match after.get(column.name) {
            None =>
              issues.push({
                "table": table.name,
                "column": column.name,
                "kind": "missing_column",
              })
            Some(changed) => {
              if column.declared_type != changed.declared_type {
                issues.push({
                  "table": table.name,
                  "column": column.name,
                  "kind": "declared_type",
                  "expected": column.declared_type,
                  "actual": changed.declared_type,
                })
              }
              if column.required != changed.required {
                issues.push({
                  "table": table.name,
                  "column": column.name,
                  "kind": "nullability",
                  "expected": column.required,
                  "actual": changed.required,
                })
              }
              if column.key_position != changed.key_position {
                issues.push({
                  "table": table.name,
                  "column": column.name,
                  "kind": "primary_key",
                  "expected": column.key_position,
                  "actual": changed.key_position,
                })
              }
              let position = other.column_index(column.name).unwrap()
              if position != index {
                issues.push({
                  "table": table.name,
                  "column": column.name,
                  "kind": "column_order",
                  "expected": index,
                  "actual": position,
                })
              }
            }
          }
        }
        for column in other.columns {
          if !before.contains(column.name) {
            issues.push({
              "table": table.name,
              "column": column.name,
              "kind": "extra_column",
            })
          }
        }
      }
    }
  }
  for table in actual {
    if !wanted.contains(table.name) {
      issues.push({ "table": table.name, "kind": "extra_table" })
    }
  }
  {
    "compatible": issues.is_empty(),
    "issues": Json::array(issues),
    "automatic_migration": false,
  }
}
