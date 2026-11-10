///|
/// Blackbox tests for the schema-driven formatting.

///|
test "schema_type reads a simple type" {
  assert_eq(@mcpbox.schema_type(@json.parse("{\"type\":\"string\"}")), "string")
  assert_eq(
    @mcpbox.schema_type(@json.parse("{\"type\":[\"string\",\"null\"]}")),
    "string | null",
  )
  assert_eq(@mcpbox.schema_type(Json::object(Map([]))), "any")
}

///|
test "schema_type falls back to enum" {
  assert_eq(
    @mcpbox.schema_type(@json.parse("{\"enum\":[\"a\",\"b\"]}")),
    "enum",
  )
}

///|
test "render_params marks optional parameters and sorts them" {
  let tool = @mcpbox.parse_tool(
    @json.parse(
      "{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"b\":{\"type\":\"integer\"},\"a\":{\"type\":\"string\"}},\"required\":[\"a\"]}}",
    ),
  )
  assert_eq(@mcpbox.render_tool_signature(tool), "t(a: string, b?: integer)")
}

///|
test "render_params is empty for a tool with no properties" {
  let tool = @mcpbox.parse_tool(
    @json.parse("{\"name\":\"t\",\"inputSchema\":{\"type\":\"object\"}}"),
  )
  assert_eq(@mcpbox.render_tool_signature(tool), "t()")
}

///|
test "first_line keeps only the first line" {
  assert_eq(@mcpbox.first_line("one\ntwo"), "one")
  assert_eq(@mcpbox.first_line("  spaced  "), "spaced")
}

///|
test "tool_to_json round-trips the important fields" {
  let tool = @mcpbox.parse_tool(
    @json.parse(
      "{\"name\":\"t\",\"title\":\"T\",\"description\":\"d\",\"inputSchema\":{\"type\":\"object\"}}",
    ),
  )
  let json = @mcpbox.tool_to_json(tool)
  let decoded = @json.parse(json.stringify())
  match decoded {
    Object(obj) => {
      assert_eq(obj.get("name"), Some(Json::string("t")))
      assert_eq(obj.get("title"), Some(Json::string("T")))
      assert_eq(obj.get("description"), Some(Json::string("d")))
    }
    _ => abort("expected an object")
  }
}

///|
/// `count=5` must become the JSON number `5`, not the string `"5"`.
test "coerce_value turns a small integer into a JSON number" {
  let schema = @json.parse("{\"type\":\"integer\"}")
  assert_eq(@mcpbox.coerce_value("5", Some(schema)).stringify(), "5")
  assert_eq(@mcpbox.coerce_value(" -5 ", Some(schema)).stringify(), "-5")
  assert_eq(@mcpbox.coerce_value("+7", Some(schema)).stringify(), "7")
}

///|
/// MCP schemas call 64-bit ids and millisecond timestamps `integer`, so an
/// `Int32`-only parse would silently demote them to JSON strings.
test "coerce_value keeps integers beyond Int32 as JSON numbers" {
  let schema = @json.parse("{\"type\":\"integer\"}")
  assert_eq(
    @mcpbox.coerce_value("2147483648", Some(schema)).stringify(),
    "2147483648",
  )
  assert_eq(
    @mcpbox.coerce_value("1712345678901", Some(schema)).stringify(),
    "1712345678901",
  )
  assert_eq(
    @mcpbox.coerce_value("9007199254740992", Some(schema)).stringify(),
    "9007199254740992",
  )
}

///|
/// Anything that is not a plain integer stays a string rather than being
/// rounded or rejected, so a caller sees their own input echoed back.
test "coerce_value leaves non-integers for an integer schema as strings" {
  let schema = @json.parse("{\"type\":\"integer\"}")
  for raw in ["1.5", "1e9", "abc", "", "9007199254740993", "Infinity"] {
    assert_eq(
      @mcpbox.coerce_value(raw, Some(schema)).stringify(),
      "\"" + raw + "\"",
    )
  }
}

///|
test "coerce_value keeps Infinity and NaN out of JSON numbers" {
  let schema = @json.parse("{\"type\":\"number\"}")
  assert_eq(@mcpbox.coerce_value("1.5", Some(schema)).stringify(), "1.5")
  assert_eq(
    @mcpbox.coerce_value("Infinity", Some(schema)).stringify(),
    "\"Infinity\"",
  )
  assert_eq(@mcpbox.coerce_value("NaN", Some(schema)).stringify(), "\"NaN\"")
}

///|
test "coerce_value splits arrays and coerces their items" {
  let schema = @json.parse(
    "{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}",
  )
  assert_eq(@mcpbox.coerce_value("1, 2,3", Some(schema)).stringify(), "[1,2,3]")
}
