///|
/// SQLite storage classes. Integers are never converted through floating point.
pub(all) enum Value {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Debug, Eq)

///|
pub suberror CdcError {
  Invalid(String)
  Conflict(String)
  Stale(String)
  Corrupt(String)
} derive(Debug)

///|
pub fn Value::storage_class(self : Value) -> String {
  match self {
    Null => "null"
    Integer(_) => "integer"
    Real(_) => "real"
    Text(_) => "text"
    Blob(_) => "blob"
  }
}

///|
pub fn Value::validate(self : Value) -> Unit raise CdcError {
  if self is Real(v) && (v - v).is_nan() {
    raise Invalid("Non-finite REAL is not supported by the wire protocol")
  }
}

///|
pub fn encode_hex(bytes : Bytes) -> String {
  let out = StringBuilder()
  let digits = "0123456789abcdef".to_array()
  for b in bytes {
    let n = b.to_int()
    out.write_char(digits[n / 16])
    out.write_char(digits[n % 16])
  }
  out.to_string()
}

///|
fn hex_digit(c : UInt16) -> Int32 raise CdcError {
  let n = c.to_int()
  if n >= 48 && n <= 57 {
    n - 48
  } else if n >= 65 && n <= 70 {
    n - 55
  } else if n >= 97 && n <= 102 {
    n - 87
  } else {
    raise Invalid("Invalid hexadecimal digit")
  }
}

///|
pub fn decode_hex(text : String) -> Bytes raise CdcError {
  if text.length() % 2 != 0 {
    raise Invalid("Hexadecimal BLOB must have even length")
  }
  let values : Array[Byte] = []
  for i in 0..<(text.length() / 2) {
    values.push(
      (hex_digit(text[i * 2]) * 16 + hex_digit(text[i * 2 + 1])).to_byte(),
    )
  }
  Bytes::from_iter(values.iter())
}

///|
pub fn parse_integer(text : String) -> Int64 raise CdcError {
  if text.is_empty() {
    raise Invalid("Empty integer")
  }
  let negative = text.has_prefix("-")
  let offset = if negative { 1 } else { 0 }
  if text.length() == offset {
    raise Invalid("Integer has no digits")
  }
  let limit = if negative {
    -9223372036854775807L - 1L
  } else {
    -9223372036854775807L
  }
  let mut result = 0L
  for i in offset..<text.length() {
    let digit = text[i].to_int() - 48
    if digit < 0 || digit > 9 {
      raise Invalid("Invalid decimal integer: " + text)
    }
    if result < limit / 10L {
      raise Invalid("Integer overflow")
    }
    result *= 10L
    if result < limit + digit.to_int64() {
      raise Invalid("Integer overflow")
    }
    result -= digit.to_int64()
  }
  if negative {
    result
  } else {
    -result
  }
}

///|
pub fn Value::to_wire(self : Value) -> Json raise CdcError {
  self.validate()
  match self {
    Null => Json::array([Json::string("null")])
    Integer(v) =>
      Json::array([Json::string("integer"), Json::string(v.to_string())])
    Real(v) => Json::array([Json::string("real"), Json::number(v)])
    Text(v) => Json::array([Json::string("text"), Json::string(v)])
    Blob(v) => Json::array([Json::string("blob"), Json::string(encode_hex(v))])
  }
}

///|
pub fn Value::from_wire(value : Json) -> Value raise CdcError {
  let result = match value {
    ["null"] => Null
    ["integer", String(v)] => Integer(parse_integer(v))
    ["real", Number(v, ..)] => Real(v)
    ["text", String(v)] => Text(v)
    ["blob", String(v)] => Blob(decode_hex(v))
    _ => raise Invalid("Expected tagged SQLite value")
  }
  result.validate()
  result
}

///|
pub fn parse_json(text : String) -> Json raise CdcError {
  @json.parse(text) catch {
    _ => raise Invalid("Invalid JSON document")
  }
}

///|
pub fn field(value : Json, name : String) -> Json raise CdcError {
  match value {
    Object(map) =>
      match map.get(name) {
        Some(v) => v
        None => raise Invalid("Missing field: " + name)
      }
    _ => raise Invalid("Expected JSON object")
  }
}

///|
pub fn string_field(value : Json, name : String) -> String raise CdcError {
  match field(value, name) {
    String(text) => text
    _ => raise Invalid("Expected string field: " + name)
  }
}

///|
pub fn integer_field(value : Json, name : String) -> Int64 raise CdcError {
  parse_integer(string_field(value, name))
}

///|
pub fn array_field(value : Json, name : String) -> Array[Json] raise CdcError {
  match field(value, name) {
    Array(values) => values
    _ => raise Invalid("Expected array field: " + name)
  }
}

///|
pub fn boolean_field(value : Json, name : String) -> Bool raise CdcError {
  match field(value, name) {
    True => true
    False => false
    _ => raise Invalid("Expected boolean field: " + name)
  }
}
