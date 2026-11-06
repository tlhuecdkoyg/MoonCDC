///|
fn validate_text(value : String) -> Unit raise CdcError {
  let mut index = 0
  while index < value.length() {
    let unit = value[index].to_int()
    if unit >= 0xd800 && unit <= 0xdbff {
      if index + 1 >= value.length() ||
        value[index + 1].to_int() < 0xdc00 ||
        value[index + 1].to_int() > 0xdfff {
        raise Invalid("TEXT contains an unpaired UTF-16 surrogate")
      }
      index += 2
    } else {
      if unit >= 0xdc00 && unit <= 0xdfff {
        raise Invalid("TEXT contains an unpaired UTF-16 surrogate")
      }
      index += 1
    }
  }
}

///|
fn decode_text(hex : String) -> String raise CdcError {
  @utf8.decode(decode_hex(hex), ignore_bom=false) catch {
    _ =>
      raise Invalid(
        "SQLite TEXT is not valid UTF-8; use BLOB for arbitrary bytes",
      )
  }
}
