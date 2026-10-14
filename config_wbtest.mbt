///|
/// Whitebox tests for the config parser: the JSONC cleaner, environment
/// substitution and the server-definition decoder.

///|
test "strip_jsonc_comments removes comments but keeps string contents" {
  let input = "{\n  // a line comment\n  \"a\": 1, /* inline */ \"b\": \"// not a comment\"\n}"
  let out = strip_jsonc_comments(input)
  assert_false(out.contains("// a line comment"))
  assert_false(out.contains("/* inline */"))
  assert_true(out.contains("\"// not a comment\""))
}

///|
test "strip_jsonc_comments leaves an unterminated block alone" {
  let out = strip_jsonc_comments("{\"a\": 1}")
  assert_eq(out, "{\"a\": 1}")
}

///|
test "strip_trailing_commas drops separators before closers" {
  assert_eq(strip_trailing_commas("{\"a\":1,}"), "{\"a\":1}")
  assert_eq(strip_trailing_commas("[1,2,]"), "[1,2]")
  assert_eq(strip_trailing_commas("{\"a\":1, \"b\":2}"), "{\"a\":1, \"b\":2}")
  // A comma inside a string is untouched.
  assert_eq(strip_trailing_commas("{\"a\":\",}\"}"), "{\"a\":\",}\"}")
}

///|
test "parse_jsonc accepts comments and trailing commas" {
  let json = parse_jsonc("{\n // hi\n \"a\": [1, 2,],\n}")
  assert_eq(json.stringify(), "{\"a\":[1,2]}")
}

///|
test "parse_jsonc rejects broken JSON" {
  let failed = try {
    ignore(parse_jsonc("{\"a\":"))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "expand_env substitutes, falls back, and blanks missing names" {
  @env.set_env_var("MCPBOX_TEST_VAR", "hello")
  assert_eq(expand_env("a-${MCPBOX_TEST_VAR}-b"), "a-hello-b")
  assert_eq(expand_env("${MCPBOX_TEST_VAR:-fallback}"), "hello")
  assert_eq(expand_env("${MCPBOX_TEST_MISSING:-fallback}"), "fallback")
  assert_eq(expand_env("${MCPBOX_TEST_MISSING}"), "")
  assert_eq(expand_env("no placeholders"), "no placeholders")
  @env.unset_env_var("MCPBOX_TEST_VAR")
}

///|
test "servers_from_document reads stdio and http definitions" {
  let document = parse_jsonc(
    "{\"mcpServers\":{\"a\":{\"command\":\"npx\",\"args\":[\"-y\",\"x\"]},\"b\":{\"url\":\"https://example.com/mcp\",\"headers\":{\"X\":\"1\"}}}}",
  )
  let servers = servers_from_document(document, "mcpServers", "test.json")
  assert_eq(servers.length(), 2)
  assert_eq(servers[0].name, "a")
  match servers[0].kind {
    Stdio(spec) => {
      assert_eq(spec.command, "npx")
      assert_eq(spec.args.join(" "), "-y x")
    }
    _ => abort("expected a stdio server")
  }
  match servers[1].kind {
    Http(spec) => {
      assert_eq(spec.url, "https://example.com/mcp")
      assert_eq(spec.headers.get("X"), Some("1"))
    }
    _ => abort("expected an http server")
  }
}

///|
test "servers_from_document honours the servers key for VS Code" {
  let document = parse_jsonc(
    "{\"servers\":{\"v\":{\"type\":\"http\",\"url\":\"https://x/mcp\"}}}",
  )
  let servers = servers_from_document(document, "servers", "mcp.json")
  assert_eq(servers.length(), 1)
  match servers[0].kind {
    Http(spec) => assert_eq(spec.url, "https://x/mcp")
    _ => abort("expected an http server")
  }
}

///|
test "servers_from_document skips a document without the key" {
  let document = parse_jsonc("{\"other\":1}")
  assert_eq(servers_from_document(document, "mcpServers", "x.json").length(), 0)
}

///|
test "parse_server rejects a definition with no transport" {
  let failed = try {
    ignore(parse_server("x", Json::object(Map([])), "test.json"))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "parse_server reports a missing HTTP url" {
  let failed = try {
    ignore(
      parse_server("x", parse_jsonc("{\"transport\":\"http\"}"), "test.json"),
    )
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "parse_server infers HTTP from a url" {
  let server = parse_server(
    "x",
    parse_jsonc("{\"url\":\"https://example.com/mcp\"}"),
    "test.json",
  )
  match server.kind {
    Http(spec) => assert_eq(spec.url, "https://example.com/mcp")
    _ => abort("expected an http server")
  }
}

///|
test "parse_server expands the environment in command and env" {
  @env.set_env_var("MCPBOX_TEST_TOKEN", "secret")
  let server = parse_server(
    "x",
    parse_jsonc(
      "{\"command\":\"run\",\"env\":{\"TOKEN\":\"${MCPBOX_TEST_TOKEN}\"}}",
    ),
    "test.json",
  )
  match server.kind {
    Stdio(spec) => assert_eq(spec.env.get("TOKEN"), Some("secret"))
    _ => abort("expected a stdio server")
  }
  @env.unset_env_var("MCPBOX_TEST_TOKEN")
}

///|
test "config_candidates puts project files before user files" {
  let candidates = config_candidates()
  assert_true(candidates.length() > 0)
  assert_eq(candidates[0].path, "./mcpbox.json")
  assert_eq(candidates[0].key, "mcpServers")
}

///|
test "config_candidates reads ~/.mcpbox.json before the XDG file" {
  let candidates = config_candidates()
  let mut home_index = -1
  let mut xdg_index = -1
  for i, candidate in candidates {
    if candidate.path.has_suffix("/.mcpbox.json") {
      home_index = i
    }
    if candidate.path.has_suffix("/mcpbox/config.json") {
      xdg_index = i
    }
  }
  assert_true(home_index >= 0)
  assert_true(xdg_index >= 0)
  assert_true(home_index < xdg_index)
  assert_eq(candidates[home_index].key, "mcpServers")
}
