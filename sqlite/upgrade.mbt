///|
/// Upgrade intact 0.2.0 or 0.3.0/0.3.1 triggers in one write transaction. Existing journals,
/// source identity, retention floor and consumer cursors remain unchanged.
/// Unknown definitions or undecodable retained events prevent any mutation.
pub fn Database::upgrade_capture(
  self : Database,
  max_events~ : Int32 = 100000,
) -> Json raise {
  if max_events <= 0 || max_events > 1000000 {
    raise StoreError("Invalid upgrade audit budget")
  }
  self.begin(true)
  defer self.rollback()
  self.verify_capture_internal(true)
  self.check_journal(max_events) |> ignore
  let mut changed = 0
  for
    row in self.query(
      "SELECT id,schema_json FROM _mooncdc_tables ORDER BY id",
      [],
    ) {
    let id = integer(row.values[0]).to_int()
    let table = @cdc.Table::from_wire(@cdc.parse_json(text(row.values[1])))
    for operation in [@cdc.Insert, @cdc.Update, @cdc.Delete] {
      let name = @cdc.trigger_name(id, operation)
      let expected = table.trigger_sql(id, operation)
      if self.definition(name, "trigger") != expected {
        self.execute("DROP TRIGGER " + @cdc.quote_identifier(name), [])
        |> ignore
        self.execute(expected, []) |> ignore
        changed += 1
      }
    }
  }
  self.verify_capture()
  let report : Json = {
    "upgraded_triggers": changed,
    "cursor": self.source_cursor().to_wire(),
  }
  self.commit()
  report
}
