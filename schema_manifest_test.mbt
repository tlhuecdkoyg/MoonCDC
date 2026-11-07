///|
test "schema manifests enforce snapshot table count and case insensitive uniqueness" {
  let table : @MoonCDC.Table = {
    name: "items",
    columns: [
      { name: "id", declared_type: "INTEGER", required: true, key_position: 1, },
    ],
  }
  let upper : @MoonCDC.Table = { ..table, name: "ITEMS", }
  let too_many = Json::array(
    Array::makei(129, index => {
      @MoonCDC.Table::{ ..table, name: "items" + index.to_string(), }.to_wire()
    }),
  )
  for
    manifest in [
      Json::array([]),
      Json::array([table.to_wire(), table.to_wire()]),
      Json::array([table.to_wire(), upper.to_wire()]),
      too_many,
    ] {
    assert_true(
      try {
        @MoonCDC.schemas_from_wire(manifest.stringify()) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  assert_eq(@MoonCDC.schemas_from_wire(@MoonCDC.schemas_to_wire([table])), [
    table,
  ])
  let maximum = Array::makei(128, index => @MoonCDC.Table::{
    ..table,
    name: "items" + index.to_string(),
  })
  assert_eq(
    @MoonCDC.schemas_from_wire(@MoonCDC.schemas_to_wire(maximum)),
    maximum,
  )
}
