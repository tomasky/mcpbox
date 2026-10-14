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
