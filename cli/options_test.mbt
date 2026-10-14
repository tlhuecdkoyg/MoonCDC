///|
test "CLI rejects ambiguous or ineffective arguments before opening databases" {
  for
    args in [
      ["sync", "source", "target", "consumer", "--limit", "0"],
      ["sync", "source", "target", "consumer", "--limit", "3", "--limit", "4"],
      ["status", "source", "--format", "jsonl"],
      ["apply", "target"],
      ["project-batch", "--input", "-", "--plan", "-"],
      ["install", "source"],
    ] {
    assert_true(
      try {
        @cli.parse_args(args) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
  let options = @cli.parse_args([
    "sync", "--limit", "5", "--", "--source", "target", "consumer",
  ])
  assert_eq(options.limit, 5)
  assert_eq(options.arguments[0], "--source")
}
