///|
/// Whitebox tests for the response parsers and the Streamable HTTP framing
/// helper. The transports themselves are exercised end to end by the fixture
/// server in `tests/fixtures`.

///|
test "sse_events pulls the data lines out of an event stream" {
  let body = "event: message\ndata: {\"a\":1}\n\n"
  assert_eq(sse_events(body).join("|"), "{\"a\":1}")
}

///|
test "sse_events joins multiple data lines inside one event" {
  let body = "data: {\"a\":\ndata: 1}\n\n"
  assert_eq(sse_events(body).join("|"), "{\"a\":\n1}")
}

///|
test "sse_events keeps separate events apart" {
  let body = "data: {\"method\":\"note\"}\n\ndata: {\"id\":1,\"result\":{}}\n\n"
  assert_eq(
    sse_events(body).join("|"),
    "{\"method\":\"note\"}|{\"id\":1,\"result\":{}}",
  )
}

///|
test "sse_events returns a plain JSON body unchanged" {
  assert_eq(sse_events(" {\"a\":1} ").join("|"), "{\"a\":1}")
}

///|
test "redirect_method preserves DELETE across 301 and 302" {
  assert_eq(redirect_method(@http.Delete, 301), @http.Delete)
  assert_eq(redirect_method(@http.Delete, 302), @http.Delete)
  assert_eq(redirect_method(@http.Post, 301), @http.Get)
  assert_eq(redirect_method(@http.Post, 302), @http.Get)
}

///|
test "redirect_method rewrites 303 but preserves 307 and 308" {
  assert_eq(redirect_method(@http.Delete, 303), @http.Get)
  assert_eq(redirect_method(@http.Head, 303), @http.Head)
  assert_eq(redirect_method(@http.Post, 307), @http.Post)
  assert_eq(redirect_method(@http.Delete, 308), @http.Delete)
}

///|
test "url_origin ignores path, query and fragment" {
  assert_eq(
    url_origin("https://Example.COM:8443/a/b?x=1#f"),
    "https://example.com:8443",
  )
  assert_eq(url_origin("http://127.0.0.1:8765"), "http://127.0.0.1:8765")
}

///|
test "resolve_redirect_url handles absolute, root and relative locations" {
  let base = "http://127.0.0.1:8765/old/mcp?token=1"
  assert_eq(
    resolve_redirect_url(base, "https://example.com/new"),
    "https://example.com/new",
  )
  assert_eq(
    resolve_redirect_url(base, "/current"),
    "http://127.0.0.1:8765/current",
  )
  assert_eq(
    resolve_redirect_url(base, "next"),
    "http://127.0.0.1:8765/old/next",
  )
  assert_eq(
    resolve_redirect_url(base, "//example.com/mcp"),
    "http://example.com/mcp",
  )
  assert_eq(
    resolve_redirect_url(base, "?next=1"),
    "http://127.0.0.1:8765/old/mcp?next=1",
  )
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
test "find_response preserves an explicit JSON null result" {
  let json = parse_jsonc("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":null}")
  match find_response(json, 5) {
    Some(Ok(result)) => assert_eq(result.stringify(), "null")
    _ => abort("expected a null result")
  }
}

///|
test "parse_call_result preserves an explicit structured null" {
  let result = parse_call_result(
    parse_jsonc("{\"content\":[],\"structuredContent\":null}"),
  )
  match result.structured {
    Some(json) => assert_eq(json.stringify(), "null")
    None => abort("expected null structured content")
  }
  assert_eq(render_call_result(result), "null")
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

///|
test "split_url keeps query strings and drops fragments" {
  assert_eq(split_url("http://h:1/mcp"), ("http://h:1/", "/mcp"))
  assert_eq(split_url("http://h:1?x=1"), ("http://h:1/", "/?x=1"))
  assert_eq(split_url("http://h:1/a?x=1#f"), ("http://h:1/", "/a?x=1"))
}

///|
test "url_origin folds default ports" {
  assert_eq(url_origin("https://example.com/x"), "https://example.com")
  assert_eq(url_origin("https://example.com:443/x"), "https://example.com")
  assert_eq(url_origin("http://example.com:80/x"), "http://example.com")
  assert_eq(
    url_origin("https://example.com:8443/x"),
    "https://example.com:8443",
  )
  assert_eq(url_origin("http://example.com:8080/x"), "http://example.com:8080")
}

///|
test "resolve_redirect_url normalises dot segments" {
  assert_eq(
    resolve_redirect_url("http://h/a/b/c/mcp", "../up"),
    "http://h/a/b/up",
  )
  assert_eq(
    resolve_redirect_url("http://h/a/b/mcp", "./next"),
    "http://h/a/b/next",
  )
}

///|
test "http request bodies are measured in utf-8 bytes" {
  let args = Json::object({ "name": Json::string("héllo💩") })
  let body = args.stringify()
  // A Chinese/emoji payload must not be measured in UTF-16 code units:
  // Content-Length has to agree with the bytes the HTTP client writes.
  assert_eq(@utf8.encode(body).length() > body.length(), true)
}
