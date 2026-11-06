///|
test "directly constructed filters obey encoder budgets including cycles" {
  let mut nested = @MoonCDC.Predicate::Always
  for _ in 0..<34 {
    nested = Not(nested)
  }
  assert_true(
    try {
      nested.to_wire() |> ignore
      false
    } catch {
      _ => true
    },
  )
  let wide = @MoonCDC.Predicate::All(Array::make(65, Always))
  assert_true(
    try {
      wide.to_wire() |> ignore
      false
    } catch {
      _ => true
    },
  )
  let children : Array[@MoonCDC.Predicate] = []
  let cyclic = @MoonCDC.Predicate::Any(children)
  children.push(cyclic)
  assert_true(
    try {
      cyclic.to_wire() |> ignore
      false
    } catch {
      _ => true
    },
  )
}
