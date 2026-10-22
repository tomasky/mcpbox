///|
fn documented_tool() -> Tool {
  {
    name: "query-docs",
    title: "",
    description: "Look up library documentation.",
    input_schema: Json::object({
      "type": Json::string("object"),
      "required": Json::array([Json::string("query")]),
      "properties": Json::object({
        "query": Json::object({
          "type": Json::string("string"),
          "description": Json::string("What to find."),
        }),
        "language": Json::object({
          "type": Json::string("string"),
          "description": Json::string("Response language."),
          "enum": Json::array([Json::string("en"), Json::string("zh")]),
          "default": Json::string("en"),
        }),
      }),
    }),
  }
}

///|
test "tool docs include descriptions, optional parameters, enum and default" {
  assert_eq(
    render_tool_doc(documented_tool(), "  ").join("\n"),
    "  /**\n   * Look up library documentation.\n   *\n   * @param language? Response language.; choices: en, zh; default: en\n   * @param query What to find.\n   */",
  )
}

///|
test "undocumented tools do not emit empty comments" {
  let tool = parse_tool(@json.parse("{\"name\":\"bare\"}"))
  assert_eq(render_tool_doc(tool, "  "), [])
}

///|
test "list docs are on by default and no-docs restores bare signatures" {
  let server : Server = {
    name: "ct7",
    kind: Http({ url: "https://example.com/mcp", headers: Map([]), }),
    note: "",
  }
  let info : ServerInfo = {
    name: "Context7",
    version: "1",
    protocol_version: "",
    instructions: "Pick a library first.",
  }
  let report : ServerReport = {
    server,
    info: Some(info),
    tools: [documented_tool()],
    error: None,
  }
  let annotated = render_reports_text([report], parse_options([]))
  assert_true(annotated.contains("Instructions: Pick a library first."))
  assert_true(annotated.contains("Look up library documentation."))
  assert_true(annotated.contains("@param query What to find."))
  let bare = render_reports_text([report], parse_options(["--no-docs"]))
  assert_false(bare.contains("/**"))
  assert_false(bare.contains("Instructions:"))
  assert_true(bare.contains("query-docs(language?: string, query: string)"))
  let brief = render_reports_text([report], parse_options(["--brief"]))
  assert_eq(brief, "ct7  (1 tools)")
  let json = render_reports_json([report])
  assert_true(@json.parse(json) is Object(_))
  assert_false(json.contains("/**"))
}

///|
test "discovery renders names only and does not include tools" {
  let alpha : Server = {
    name: "alpha",
    kind: Stdio({ command: "echo", args: [], env: Map([]), cwd: "", }),
    note: "",
  }
  let beta : Server = {
    name: "beta",
    kind: Http({ url: "https://example.com/mcp", headers: Map([]), }),
    note: "",
  }
  assert_eq(render_server_names([alpha, beta]), "alpha\nbeta")
  let json = render_servers_json([alpha, beta])
  assert_true(json.contains("\"name\": \"alpha\""))
  assert_true(json.contains("\"name\": \"beta\""))
  assert_false(json.contains("\"tools\""))
}

///|
test "doc wrapping normalizes whitespace and keeps continuation words" {
  assert_eq(wrap_doc("one\n two\tthree four", 9), ["one two", "three", "four"])
  assert_eq(wrap_doc("  ", 10), [])
  assert_eq(render_instructions("  first\nsecond  ", "  "), [
    "  Instructions: first second",
  ])
}
