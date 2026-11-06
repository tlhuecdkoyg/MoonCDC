///|
fn store_error_message(error : Error) -> String {
  match error {
    StoreError(message) => message
    @cdc.Invalid(message)
    | @cdc.Conflict(message)
    | @cdc.Stale(message)
    | @cdc.Corrupt(message) => message
    @sqlite3.SqliteError(msg~, ..) => "SQLite: " + msg
    _ => error.to_string()
  }
}
