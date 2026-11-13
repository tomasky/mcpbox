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

///|
test "adhoc_server rejects combining --http-url with --stdio" {
  let opts = parse_options([
    "--http-url", "https://h/mcp", "--stdio", "python3 server.py",
  ])
  let failed = try {
    ignore(adhoc_server(opts))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "adhoc_server accepts --sse-url and refuses it alongside --http-url" {
  let opts = parse_options(["--sse-url", "https://h/sse"])
  match adhoc_server(opts) {
    Some(server) =>
      assert_true(server.kind is Sse({ url: "https://h/sse", headers: _, }))
    None => assert_true(false)
  }
  let both = parse_options([
    "--sse-url", "https://h/sse", "--http-url", "https://h/mcp",
  ])
  let failed = try {
    ignore(adhoc_server(both))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}
