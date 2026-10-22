///|
test "background and documentation options are opt-in switches" {
  let defaults = parse_options([])
  assert_false(defaults.no_docs)
  assert_false(defaults.all_servers)
  assert_false(defaults.background)
  assert_false(defaults.quiet)
  let opts = parse_options(["ct7", "-b", "--no-docs", "-q"])
  assert_true(opts.background)
  assert_true(opts.no_docs)
  assert_true(opts.quiet)
  assert_eq(opts.positional, ["ct7"])
  assert_true(parse_options(["--all"]).all_servers)
  assert_true(parse_options(["--background"]).background)
  assert_true(parse_options(["--quiet"]).quiet)
  let literal = parse_options(["--", "-b", "--no-docs"])
  assert_false(literal.background)
  assert_false(literal.no_docs)
  assert_eq(literal.positional, ["-b", "--no-docs"])
}

///|
test "daemon fingerprints sort nested object keys but preserve array order" {
  let first = @json.parse("{\"b\":{\"z\":1,\"a\":2},\"a\":[2,1]}")
  let second = @json.parse("{\"a\":[2,1],\"b\":{\"a\":2,\"z\":1}}")
  assert_eq(daemon_canonical(first), daemon_canonical(second))
  assert_eq(daemon_canonical(first), "{\"a\":[2,1],\"b\":{\"a\":2,\"z\":1}}")
}

///|
test "daemon decodes resolved stdio settings without environment expansion" {
  let request = Json::object({
    "name": Json::string("ct7"),
    "transport": Json::string("stdio"),
    "spec": Json::object({
      "command": Json::string("server"),
      "args": Json::array([Json::string("${LITERAL}")]),
      "env": Json::object({ "TOKEN": Json::string("${DO_NOT_EXPAND}") }),
      "cwd": Json::string("/project"),
    }),
  })
  let server = daemon_decode_server(request)
  assert_eq(server.name, "ct7")
  guard server.kind is Stdio(spec) else { abort("expected stdio") }
  assert_eq(spec.command, "server")
  assert_eq(spec.args, ["${LITERAL}"])
  assert_eq(spec.env.get("TOKEN"), Some("${DO_NOT_EXPAND}"))
  assert_eq(spec.cwd, "/project")
}

///|
test "daemon decodes HTTP headers verbatim" {
  let request = Json::object({
    "name": Json::string("remote"),
    "transport": Json::string("http"),
    "spec": Json::object({
      "url": Json::string("https://example.com/mcp"),
      "headers": Json::object({
        "Authorization": Json::string("Bearer ${literal}"),
      }),
    }),
  })
  guard daemon_decode_server(request).kind is Http(spec) else {
    abort("expected http")
  }
  assert_eq(spec.headers.get("Authorization"), Some("Bearer ${literal}"))
}

///|
test "progress line shows a spinner frame and elapsed seconds" {
  let line = progress_line("starting 2 MCP server(s)…", 0, 3400)
  assert_true(line.has_prefix("\r"))
  assert_true(line.contains("starting 2 MCP server(s)…"))
  assert_true(line.contains("⠋"))
  assert_true(line.contains("3s"))
}

///|
test "daemon locator rejects invalid ports" {
  for text in ["0", "-1", "65536", "not-a-port"] {
    let rejected = try {
      ignore(daemon_port(Json::object({ "port": Json::string(text) })))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
  assert_eq(daemon_port(Json::object({ "port": Json::string("12345") })), 12345)
}
