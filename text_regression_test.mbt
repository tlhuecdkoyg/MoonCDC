///|
test "raw UTF-8 text rejects invalid encodings before they can become TEXT" {
  for
    encoded in [
      "80", "C0AF", "EDA080", "EDBFBF", "F4908080", "F09F", "E282", "F5808080", "00FF",
      "C280FF", "FF",
    ] {
    assert_true(
      try {
        @MoonCDC.Value::from_wire(["text-utf8", encoded]) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "raw UTF-8 text preserves BOM NUL supplementary characters and empty text" {
  let cases : Array[(String, String)] = [
    ("", ""),
    ("EFBBBF", "\uFEFF"),
    ("410042", "A\u0000B"),
    ("F09F9880", "😀"),
    ("EFBBBF410042F09F9880", "\uFEFFA\u0000B😀"),
    ("65CC81", "e\u0301"),
  ]
  for (encoded, expected) in cases {
    let text = @MoonCDC.Value::from_wire(["text-utf8", encoded])
    assert_eq(text, @MoonCDC.Value::Text(expected))
    assert_eq(
      @MoonCDC.Value::from_wire(@MoonCDC.parse_json(text.to_wire().stringify())),
      text,
    )
  }
}

///|
test "direct TEXT values validate supplementary Unicode and retain its contents" {
  let text = @MoonCDC.Value::Text("\uFEFF😀\u0000尾")
  text.validate()
  assert_eq(@MoonCDC.Value::from_wire(text.to_wire()), text)
}
