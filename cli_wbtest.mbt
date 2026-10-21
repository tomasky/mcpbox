///|
test "adhoc_server rejects an HTTP URL without a scheme" {
  let opts = parse_options(["--http-url", "localhost:8080/mcp"])
  let failed = try {
    ignore(adhoc_server(opts))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
  let good = parse_options(["--http-url", "https://h/mcp"])
  assert_true(adhoc_server(good) is Some(_))
}
