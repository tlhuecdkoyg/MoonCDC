///|
fn sqlite_parameter_id(character : Int32) -> Bool {
  (character >= 48 && character <= 57) ||
  (character >= 65 && character <= 90) ||
  (character >= 97 && character <= 122) ||
  character == 95 ||
  character == 36 ||
  character >= 128
}

///|
fn sqlite_parameter_space(character : Int32) -> Bool {
  character == 32 || (character >= 9 && character <= 13)
}

///|
/// UTF-8 BLOB binding plus CAST preserves leading U+FEFF as text content. Rewrite
/// parameter tokens only; never interpolate a bound value or change its index.
/// Unary '+' removes CAST's expression affinity, keeping parameter comparisons
/// identical to SQLite text binding rather than coercing the other operand.
/// Token rules follow the bundled SQLite tokenizer, including Tcl-style names.
fn text_parameter_sql(
  sql : String,
  values : Array[@cdc.Value],
) -> String raise StoreError {
  if !values.any(value => value is Text(_)) {
    return sql
  }
  if sql.contains("\u0000") {
    raise StoreError("SQL contains a NUL character")
  }
  let output = StringBuilder()
  let names : Map[String, Int32] = Map([])
  let mut maximum = 0
  let mut index = 0
  let mut copied = 0
  while index < sql.length() {
    let character = sql[index].to_int()
    if character == 39 || character == 34 || character == 96 {
      let quote = character
      index += 1
      let mut closed = false
      while index < sql.length() {
        if sql[index].to_int() == quote {
          index += 1
          if index < sql.length() && sql[index].to_int() == quote {
            index += 1
          } else {
            closed = true
            break
          }
        } else {
          index += 1
        }
      }
      if !closed {
        raise StoreError("Unterminated quoted SQL token")
      }
      continue
    }
    if character == 91 {
      index += 1
      while index < sql.length() && sql[index].to_int() != 93 {
        index += 1
      }
      if index == sql.length() {
        raise StoreError("Unterminated bracketed SQL identifier")
      }
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
    let start = index
    let parameter = if character == 63 {
      index += 1
      let digits = index
      let mut number = 0
      while index < sql.length() {
        let digit = sql[index].to_int() - 48
        if digit < 0 || digit > 9 {
          break
        }
        if number > (2147483647 - digit) / 10 {
          raise StoreError("SQLite parameter index is too large")
        }
        number = number * 10 + digit
        index += 1
      }
      let position = if index == digits {
        if maximum == 2147483647 {
          raise StoreError("Too many SQLite parameters")
        }
        maximum + 1
      } else {
        if number == 0 {
          raise StoreError("SQLite parameter indices start at one")
        }
        number
      }
      maximum = maximum.max(position)
      position
    } else if character == 58 ||
      character == 64 ||
      character == 36 ||
      character == 35 {
      index += 1
      let mut identifiers = 0
      while index < sql.length() {
        let current = sql[index].to_int()
        if sqlite_parameter_id(current) {
          identifiers += 1
          index += 1
        } else if current == 58 &&
          index + 1 < sql.length() &&
          sql[index + 1].to_int() == 58 {
          index += 2
        } else if current == 40 && identifiers > 0 {
          index += 1
          while index < sql.length() && sql[index].to_int() != 41 {
            if sqlite_parameter_space(sql[index].to_int()) {
              raise StoreError("Whitespace in SQLite Tcl parameter suffix")
            }
            index += 1
          }
          if index == sql.length() {
            raise StoreError("Unterminated SQLite Tcl parameter suffix")
          }
          index += 1
          break
        } else {
          break
        }
      }
      if identifiers == 0 {
        raise StoreError("Empty SQLite named parameter")
      }
      let name = sql.view(start_offset=start, end_offset=index).to_owned()
      match names.get(name) {
        Some(position) => position
        None => {
          if maximum == 2147483647 {
            raise StoreError("Too many SQLite parameters")
          }
          maximum += 1
          names[name] = maximum
          maximum
        }
      }
    } else {
      // '$' is legal inside an ordinary identifier. Consume the whole identifier
      // so its suffix cannot be mistaken for a separate named parameter.
      index += 1
      if sqlite_parameter_id(character) {
        while index < sql.length() && sqlite_parameter_id(sql[index].to_int()) {
          index += 1
        }
      }
      continue
    }
    if parameter <= values.length() && values[parameter - 1] is Text(_) {
      output.write_view(sql.view(start_offset=copied, end_offset=start))
      output.write_string("+CAST(")
      output.write_view(sql.view(start_offset=start, end_offset=index))
      output.write_string(" AS TEXT)")
      copied = index
    }
  }
  output.write_view(sql.view(start_offset=copied))
  output.to_string()
}
