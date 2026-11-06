///|
/// Read source values as tagged SQL JSON, validating TEXT bytes before any
/// connection binding converts them to UTF-16. Requires a UTF-8 database.
pub fn Table::capture_select_sql(self : Table) -> String raise CdcError {
  self.validate()
  let values = self.columns.map(column => {
    "json(" + sqlite_wire_value(quote_identifier(column.name), false) + ")"
  })
  let keys = self
    .key_indexes()
    .map(index => quote_identifier(self.columns[index].name))
  "SELECT json_array(" +
  values.join(",") +
  ") FROM " +
  quote_identifier(self.name) +
  " ORDER BY " +
  keys.join(",")
}
