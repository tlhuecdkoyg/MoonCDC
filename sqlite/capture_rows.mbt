///|
fn Database::read_capture_rows(
  self : Database,
  table : @cdc.Table,
  max_rows : Int32,
) -> Array[@cdc.Row] raise {
  self
  .query(table.capture_select_sql(), [], max_rows~)
  .map(encoded => {
    let row = @cdc.Row::from_wire(@cdc.parse_json(text(encoded.values[0])))
    row.validate(table)
    row
  })
}
