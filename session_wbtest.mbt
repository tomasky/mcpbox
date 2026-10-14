///|
/// Whitebox tests for the response parsers and the Streamable HTTP framing
/// helper. The transports themselves are exercised end to end by the fixture
/// server in `tests/fixtures`.

///|
test "extract_sse pulls the data lines out of an event stream" {
  let body = "event: message\ndata: {\"a\":1}\n\n"
  assert_eq(extract_sse(body), "{\"a\":1}")
}

///|
test "extract_sse joins multiple data lines" {
  let body = "data: {\"a\":\ndata: 1}\n\n"
  assert_eq(extract_sse(body), "{\"a\":1}")
}

///|
test "extract_sse returns a plain JSON body unchanged" {
  assert_eq(extract_sse(" {\"a\":1} "), "{\"a\":1}")
}

///|
test "parse_tools reads names and schemas" {
  let tools = parse_tools(
    parse_jsonc(
      "{\"tools\":[{\"name\":\"a\",\"description\":\"A\"},{\"name\":\"b\",\"inputSchema\":{\"type\":\"object\"}}]}",
    ),
  )
  assert_eq(tools.length(), 2)
  assert_eq(tools[0].name, "a")
  assert_eq(tools[0].description, "A")
  assert_eq(tools[1].input_schema.stringify(), "{\"type\":\"object\"}")
}

///|
test "parse_tools rejects a malformed result" {
  let failed = try {
    ignore(parse_tools(Json::array([])))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "parse_tool rejects a descriptor with no name" {
  let failed = try {
    ignore(parse_tool(Json::object(Map([]))))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "parse_call_result reads text content and isError" {
  let result = parse_call_result(
    parse_jsonc(
      "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"isError\":true}",
    ),
  )
  assert_eq(result.content.length(), 1)
  assert_eq(result.is_error, true)
  match result.content[0] {
    Text(text) => assert_eq(text, "hi")
    _ => abort("expected text content")
  }
}

///|
test "parse_call_result reads structured content" {
  let result = parse_call_result(
    parse_jsonc("{\"content\":[],\"structuredContent\":{\"x\":1}}"),
  )
  assert_eq(result.structured.unwrap().stringify(), "{\"x\":1}")
}

///|
test "parse_content recognises images and keeps unknown kinds raw" {
  match
    parse_content(
      parse_jsonc(
        "{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"abc\"}",
      ),
    ) {
    Image(mime_type, data) => {
      assert_eq(mime_type, "image/png")
      assert_eq(data, "abc")
    }
    _ => abort("expected an image")
  }
  match parse_content(parse_jsonc("{\"type\":\"future\",\"x\":1}")) {
    Unknown(raw) => assert_eq(raw.stringify(), "{\"type\":\"future\",\"x\":1}")
    _ => abort("expected an unknown block")
  }
}

///|
test "find_response locates a response inside a batch" {
  let json = parse_jsonc(
    "[{\"jsonrpc\":\"2.0\",\"method\":\"note\"},{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{\"x\":1}}]",
  )
  match find_response(json, 5) {
    Some(Ok(result)) => assert_eq(result.stringify(), "{\"x\":1}")
    _ => abort("expected a result")
  }
}

///|
test "find_response surfaces a batched error" {
  let json = parse_jsonc(
    "[{\"jsonrpc\":\"2.0\",\"id\":5,\"error\":{\"code\":1,\"message\":\"bad\"}}]",
  )
  match find_response(json, 5) {
    Some(Err(error)) => assert_eq(error.message, "bad")
    _ => abort("expected an error")
  }
}

///|
test "find_response returns none for an unrelated id" {
  let json = parse_jsonc("{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}")
  assert_true(find_response(json, 5) is None)
}

///|
test "split_url separates the origin from the path" {
  assert_eq(
    split_url("http://127.0.0.1:8765/mcp"),
    ("http://127.0.0.1:8765/", "/mcp"),
  )
  assert_eq(
    split_url("https://mcp.example.com/a/b"),
    ("https://mcp.example.com/", "/a/b"),
  )
}

///|
test "split_url gives a bare host the root path" {
  assert_eq(split_url("http://localhost:1"), ("http://localhost:1/", "/"))
  assert_eq(
    split_url("https://mcp.example.com"),
    ("https://mcp.example.com/", "/"),
  )
}
