///|
priv enum QueryScope {
  Unscoped
  Owned
  Nested
}

///|
/// WITH can introduce either a SELECT or a write. Scope both conservatively;
/// PRAGMA and explicit transaction commands retain SQLite's existing semantics.
fn query_requires_scope(sql : String) -> Bool {
  let mut index = 0
  while index < sql.length() {
    let character = sql[index].to_int()
    if character == 32 ||
      (character >= 9 && character <= 13) ||
      character == 0xfeff ||
      character == 59 {
      index += 1
      continue
    }
    if character == 45 &&
      index + 1 < sql.length() &&
      sql[index + 1].to_int() == 45 {
      index += 2
      while index < sql.length() && sql[index].to_int() != 10 {
        index += 1
      }
      continue
    }
    if character == 47 &&
      index + 1 < sql.length() &&
      sql[index + 1].to_int() == 42 {
      index += 2
      while index < sql.length() {
        if sql[index].to_int() == 42 &&
          index + 1 < sql.length() &&
          sql[index + 1].to_int() == 47 {
          index += 2
          break
        }
        index += 1
      }
      continue
    }
    break
  }
  let start = index
  while index < sql.length() {
    let character = sql[index].to_int()
    if (character >= 65 && character <= 90) ||
      (character >= 97 && character <= 122) {
      index += 1
    } else {
      break
    }
  }
  let keyword = sql
    .view(start_offset=start, end_offset=index)
    .to_owned()
    .to_upper()
  ["INSERT", "UPDATE", "DELETE", "REPLACE", "WITH"].contains(keyword)
}

///|
/// The binding does not expose sqlite3_get_autocommit. A nested BEGIN fails
/// without modifying SQLite transaction state; match only its exact diagnostic.
fn Database::try_begin_query_transaction(self : Database) -> Bool raise {
  self.begin(false) catch {
    @sqlite3.SqliteError(
      code=@sqlite3.Error,
      msg="cannot start a transaction within a transaction",
      ..
    ) => return false
    error => raise error
  }
  true
}

///|
fn Database::begin_query_scope(
  self : Database,
  sql : String,
) -> QueryScope raise {
  if !query_requires_scope(sql) {
    return Unscoped
  }
  if self.try_begin_query_transaction() {
    return Owned
  }
  self.execute("SAVEPOINT _mooncdc_query_scope", []) |> ignore
  Nested
}

///|
fn Database::commit_query_scope(
  self : Database,
  scope : QueryScope,
) -> Unit raise {
  match scope {
    Unscoped => ()
    Owned => self.commit()
    Nested =>
      self.execute("RELEASE SAVEPOINT _mooncdc_query_scope", []) |> ignore
  }
}

///|
fn Database::rollback_query_transaction(self : Database) -> Unit raise {
  (self.execute("ROLLBACK", []) |> ignore) catch {
    // SQLite's explicit OR ROLLBACK policy and some storage errors may have
    // already ended the transaction. Other cleanup failures must be reported.
    @sqlite3.SqliteError(
      code=@sqlite3.Error,
      msg="cannot rollback - no transaction is active",
      ..
    ) => ()
    error => raise error
  }
}

///|
fn Database::rollback_query_scope(
  self : Database,
  scope : QueryScope,
) -> Unit raise {
  match scope {
    Unscoped => ()
    Owned => self.rollback_query_transaction()
    Nested => {
      (self.execute("ROLLBACK TO SAVEPOINT _mooncdc_query_scope", []) |> ignore) catch {
        @sqlite3.SqliteError(
          code=@sqlite3.Error,
          msg="no such savepoint: _mooncdc_query_scope",
          ..
        ) => {
          // OR ROLLBACK can end even the caller's outer transaction. Verify
          // that it ended instead of silently leaving an unknown live scope.
          if self.try_begin_query_transaction() {
            self.rollback_query_transaction()
            return ()
          }
          raise StoreError(
            "Query cleanup failed: private savepoint is missing while the surrounding transaction is still active",
          )
        }
        error => raise error
      }
      self.execute("RELEASE SAVEPOINT _mooncdc_query_scope", []) |> ignore
    }
  }
}
