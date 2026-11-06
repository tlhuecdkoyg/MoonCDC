///|
test "binary REAL rejects overflow underflow and malformed inputs rather than rounding" {
  let invalid : Array[Json] = [
    ["real", "9007199254740992", "0"],
    ["real", "-9007199254740992", "0"],
    ["real", "1", "1024"],
    ["real", "3", "1023"],
    ["real", "1", "-1127"],
    ["real", "1", "-1075"],
    ["real", "4503599627370497", "-1126"],
    ["real", "0", "1"],
    ["real", "one", "0"],
    ["real", "1", "1.0"],
    ["real", "1", 0],
    ["real", "NaN"],
    ["real", "Infinity"],
    ["real", "1e9999"],
  ]
  for value in invalid {
    assert_true(
      try {
        @MoonCDC.Value::from_wire(value) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  // SQL's normalized minimum subnormal uses 53 bits and a smaller exponent.
  let valid : Array[(Json, UInt64)] = [
    (["real", "4503599627370496", "-1126"], 1UL),
    (["real", "-4503599627370496", "-1126"], 0x8000000000000001UL),
    (["real", "9007199254740991", "971"], 0x7fefffffffffffffUL),
    (["real", "-0", "0"], 0x8000000000000000UL),
  ]
  for (value, expected) in valid {
    match @MoonCDC.Value::from_wire(value) {
      Real(number) => assert_eq(number.reinterpret_as_uint64(), expected)
      _ => abort("Expected REAL")
    }
  }
}
