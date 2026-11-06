///|
fn decoded_real_bits(value : @MoonCDC.Value) -> UInt64 {
  match value {
    Real(number) => number.reinterpret_as_uint64()
    _ => abort("Expected REAL after wire decoding")
  }
}

///|
test "REAL wire round trips preserve every finite binary64 bit" {
  let boundaries : Array[UInt64] = [
    0x0000000000000000UL, 0x8000000000000000UL, 0x0000000000000001UL, 0x8000000000000001UL,
    0x000fffffffffffffUL, 0x0010000000000000UL, 0x0010000000000001UL, 0x3fefffffffffffffUL,
    0x3ff0000000000000UL, 0x3ff0000000000001UL, 0x7e37e43c8800759cUL, // 1e300
     0xfe37e43c8800759cUL, 0x7fefffffffffffffUL, 0xffefffffffffffffUL,
  ]
  for bits in boundaries {
    let value = @MoonCDC.Value::Real(bits.reinterpret_as_double())
    let wire = @MoonCDC.parse_json(value.to_wire().stringify())
    assert_eq(decoded_real_bits(@MoonCDC.Value::from_wire(wire)), bits)
  }
  let mut bits = 0x93ab15cde4f61209UL
  for _ in 0..<2048 {
    bits = bits * 6364136223846793005UL + 1442695040888963407UL
    if (bits & 0x7ff0000000000000UL) == 0x7ff0000000000000UL {
      continue
    }
    let value = @MoonCDC.Value::Real(bits.reinterpret_as_double())
    assert_eq(
      decoded_real_bits(
        @MoonCDC.Value::from_wire(
          @MoonCDC.parse_json(value.to_wire().stringify()),
        ),
      ),
      bits,
    )
  }
}

///|
test "legacy decimal REAL captures decode their actual decimal value" {
  let cases : Array[(String, UInt64)] = [
    // Legacy printf text can already be lossy; decoding cannot infer its origin.
    ("9.99999999999999956e+299", 0x7e37e43c8800759bUL),
    ("-9.99999999999999956e+299", 0xfe37e43c8800759bUL),
    ("1e300", 0x7e37e43c8800759cUL),
    ("-1e300", 0xfe37e43c8800759cUL),
    ("1.000000000000000052e+299", 0x7e031cfd3999f7b0UL),
    ("4.9406564584124654e-324", 0x0000000000000001UL),
    ("-4.9406564584124654e-324", 0x8000000000000001UL),
    ("2.2250738585072014e-308", 0x0010000000000000UL),
    ("1.7976931348623157e+308", 0x7fefffffffffffffUL),
  ]
  for (decimal, expected) in cases {
    let value = @MoonCDC.Value::from_wire(["real", decimal])
    assert_eq(decoded_real_bits(value), expected)
  }
}
