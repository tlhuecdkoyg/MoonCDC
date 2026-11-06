///|
/// Encode the binary64 value as an exact integer times an integral power of two.
/// No floating-point formatting or decimal parsing is involved.
fn real_to_wire(value : Double) -> Json {
  let bits = value.reinterpret_as_uint64()
  let negative = bits >> 63 != 0UL
  let stored_exponent = ((bits >> 52) & 2047UL).to_int()
  let fraction = bits & 0x000fffffffffffffUL
  let mut significand = if stored_exponent == 0 {
    fraction
  } else {
    fraction | 0x0010000000000000UL
  }
  let mut exponent = if stored_exponent == 0 {
    -1074
  } else {
    stored_exponent - 1075
  }
  if significand == 0UL {
    exponent = 0
  } else {
    let zeros = significand.ctz()
    significand = significand >> zeros
    exponent += zeros
  }
  let digits = (if negative { "-" } else { "" }) + significand.to_string()
  Json::array([
    Json::string("real"),
    Json::string(digits),
    Json::string(exponent.to_string()),
  ])
}

///|
/// Only exactly representable finite binary64 pairs are accepted; never round.
fn real_from_binary(
  significand : String,
  exponent : String,
) -> Double raise CdcError {
  let signed = parse_integer(significand)
  if signed < -9007199254740991L || signed > 9007199254740991L {
    raise Invalid("REAL significand exceeds 53 bits")
  }
  let power = parse_integer(exponent)
  if power < -1126L || power > 1023L {
    raise Invalid("REAL binary exponent is out of range")
  }
  let sign = if significand.has_prefix("-") {
    0x8000000000000000UL
  } else {
    0UL
  }
  let magnitude = (if signed < 0L { -signed } else { signed }).reinterpret_as_uint64()
  if magnitude == 0UL {
    if power != 0L {
      raise Invalid("REAL zero requires exponent zero")
    }
    return sign.reinterpret_as_double()
  }
  let top = 63 - magnitude.clz()
  let unbiased = top + power.to_int()
  if unbiased > 1023 {
    raise Invalid("REAL overflows binary64")
  }
  let body = if unbiased >= -1022 {
    let fraction = (magnitude << (52 - top)) & 0x000fffffffffffffUL
    ((unbiased + 1023).to_uint64() << 52) | fraction
  } else {
    let shift = power.to_int() + 1074
    if shift >= 0 {
      magnitude << shift
    } else {
      let discarded = -shift
      if discarded > 52 || (magnitude & ((1UL << discarded) - 1UL)) != 0UL {
        raise Invalid("REAL is smaller than an exact binary64 subnormal")
      }
      magnitude >> discarded
    }
  }
  (sign | body).reinterpret_as_double()
}
