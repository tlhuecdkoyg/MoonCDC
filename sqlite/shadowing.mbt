///|
/// Unqualified SQLite object names resolve TEMP before main. Captured data and
/// metadata are persistent main objects, so refuse any TEMP table/view that
/// could redirect an internal read or write while advancing a main cursor.
fn Database::require_main_namespace(
  self : Database,
  names~ : Array[String] = [],
) -> Unit raise {
  let temporary = self.query(
    "SELECT name FROM temp.sqlite_schema WHERE type IN ('table','view')",
    [],
  )
  if temporary.is_empty() {
    return
  }
  let shadows : Map[String, String] = Map([])
  for row in temporary {
    let name = text(row.values[0])
    let lower = name.to_lower()
    if lower.has_prefix("_mooncdc_") {
      raise StoreError(
        "TEMP object shadows reserved MoonCDC namespace: " + name,
      )
    }
    shadows[lower] = name
  }
  let guarded_names = names.copy()
  // Read manifests with explicit main qualification so the guard itself cannot
  // be redirected. All reserved TEMP metadata names were rejected above.
  let manifests = self.query(
    "SELECT name FROM main.sqlite_schema WHERE type='table' AND name IN ('_mooncdc_tables','_mooncdc_projection')",
    [],
  )
  for row in manifests {
    match text(row.values[0]) {
      "_mooncdc_tables" =>
        for row in self.query("SELECT name FROM main._mooncdc_tables", []) {
          guarded_names.push(text(row.values[0]))
        }
      "_mooncdc_projection" =>
        for
          row in self.query(
            "SELECT schema_json FROM main._mooncdc_projection",
            [],
          ) {
          for table in @cdc.schemas_from_wire(text(row.values[0])) {
            guarded_names.push(table.name)
          }
        }
      _ => ()
    }
  }
  for name in guarded_names {
    if shadows.get(name.to_lower()) is Some(shadow) {
      raise StoreError(
        "TEMP object shadows a captured or projected main table: " + shadow,
      )
    }
  }
}
