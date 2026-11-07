///|
fn Database::read_capture_rows(
  self : Database,
  table : @cdc.Table,
  max_rows : Int32,
  key? : @cdc.Row,
) -> Array[@cdc.Row] raise {
  let select = table.capture_select_sql()
  let statement : @cdc.Statement = match key {
    None => { sql: select, parameters: [], }
    Some(key) => {
      let predicate = table.key_predicate(key)
      let name = @cdc.quote_identifier(table.name)
      // Filter the persistent table before the existing tagged SQL decoder.
      // Qualifying main prevents this CTE from referring to itself. SQLite can
      // retain its primary-key lookup while raw TEXT bytes avoid UTF-16 coercion.
      {
        sql: "WITH " +
        name +
        " AS (SELECT * FROM main." +
        name +
        " WHERE " +
        predicate.sql +
        ") " +
        select,
        parameters: predicate.parameters,
      }
    }
  }
  self
  .query(statement.sql, statement.parameters, max_rows~)
  .map(encoded => {
    let row = @cdc.Row::from_wire(@cdc.parse_json(text(encoded.values[0])))
    row.validate(table)
    row
  })
}
