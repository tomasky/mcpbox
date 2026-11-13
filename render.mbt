///|
/// Turning parsed results into the text or JSON a caller sees, plus the
/// schema-aware coercion that makes `key=value` arguments pleasant to write.

///|
/// The genuine integer spelling of `text`, or `None`.
///
/// JSON numbers are not bounded by `Int32` and neither are MCP schemas: a
/// millisecond timestamp or a 64-bit id is routinely typed `integer`. Parsing
/// through `Int32` would turn every such value into a JSON *string*, silently
/// breaking the tool call. So a value is accepted when it is plain digits (with
/// an optional sign) and exactly representable as a `Double`; the original
/// text is returned as the `repr` so JSON keeps the full precision instead of
/// printing `1e18` or a rounded mantissa.
fn try_int_literal(raw : String) -> String? {
  let text = raw.trim()
  let chars = text.to_array()
  let start = if chars.length() > 0 && (chars[0] == '-' || chars[0] == '+') {
    1
  } else {
    0
  }
  // Reject `1.5`, `1e9`, `nan`, and an empty (or sign-only) string: those are
  // not integers, and `number` is the type that accepts them.
  if start >= chars.length() {
    return None
  }
  for i in start..<chars.length() {
    if !(chars[i] >= '0' && chars[i] <= '9') {
      return None
    }
  }
  let value : Double = @string.parse_double(text) catch { _ => return None }
  if value.is_nan() || value.is_inf() {
    return None
  }
  // A `Double` holds every integer up to 2^53 exactly; past that the binary
  // value no longer matches what was typed, and `repr` would encode a number
  // the caller never asked for. Comparing `Double`s cannot detect this
  // (2^53+1 and 2^53 compare equal), so the text goes through `Int64` first,
  // whose accepted range is checked directly.
  let exact : Int64 = @string.parse_int64(text) catch { _ => return None }
  if exact > 9007199254740992L || exact < -9007199254740992L {
    return None
  }
  // Re-spell the number canonically. The original text may carry a leading
  // `+` or leading zeros (`+007`), and JSON forbids both; echoing the raw
  // spelling produced a body no strict parser would accept.
  Some(exact.to_string())
}

///|
/// Parse a finite double, or `None` when the text is not one. Non-JSON numeric
/// tokens such as `Infinity` and `NaN` stay strings: serialising them as JSON
/// numbers would emit invalid JSON (or, in JavaScript, `null`).
fn try_double(raw : String) -> Double? {
  let value : Double = @string.parse_double(raw.trim()) catch {
    _ => return None
  }
  if value.is_nan() || value.is_inf() {
    None
  } else {
    Some(value)
  }
}

///|
/// Coerce a `key=value` argument using the tool's schema. This is where mcpbox
/// improves on a plain string passthrough: `count=5` becomes a JSON number and
/// `tags=a,b` a JSON array when the schema says so, so callers do not have to
/// hand-write JSON for ordinary values. Anything that does not parse falls back
/// to the string, and `key:=<json>` is always available for the exact form.
pub fn coerce_value(raw : String, schema : Json?) -> Json {
  match schema {
    None => Json::string(raw)
    Some(definition) =>
      match schema_type(definition) {
        "integer" =>
          match try_int_literal(raw) {
            Some(value) => {
              let number : Double = @string.parse_double(value) catch {
                _ => 0.0
              }
              Json::number(number, repr=value)
            }
            None => Json::string(raw)
          }
        "number" =>
          match try_double(raw) {
            Some(value) => Json::number(value)
            None => Json::string(raw)
          }
        "boolean" =>
          match raw.trim() {
            "true" => Json::boolean(true)
            "false" => Json::boolean(false)
            _ => Json::string(raw)
          }
        "array" => {
          let item_schema = match definition {
            Object(obj) => obj.get("items")
            _ => None
          }
          let items : Array[Json] = []
          for item in raw.split(",") {
            items.push(coerce_value(item.trim().to_owned(), item_schema))
          }
          Json::array(items)
        }
        "object" => @json.parse(raw) catch { _ => Json::string(raw) }
        _ => Json::string(raw)
      }
  }
}

///|
/// The separator that owns a `key=value` token, and whether it is the JSON form.
///
/// The left-most separator wins, so `url:http://h/?a=1` keeps the whole URL as
/// the value instead of splitting on the `=` inside it. `:=` is an alias for
/// `=` and counts as a single separator, so the `:` in it does not win by
/// accident.
///
/// Returns `(key, value, is_json)`.
fn split_argument(pair : String) -> (String, String, Bool) raise McpError {
  let chars = pair.to_array()
  let eq = pair.find("=")
  let colon = pair.find(":")
  // Walk to the first separator, preferring the earlier of the two.
  let separator = match (eq, colon) {
    (Some(a), Some(b)) => Some(if a <= b { a } else { b })
    (Some(a), None) => Some(a)
    (None, Some(b)) => Some(b)
    (None, None) => None
  }
  guard separator is Some(index) else {
    raise fail("'" + pair + "' is not a key=value argument")
  }
  // `key:=json`: a colon immediately followed by `=`. The value starts after
  // the `=`, and the key is what came before the `:`.
  let colon_assign = chars[index] == ':' &&
    index + 1 < chars.length() &&
    chars[index + 1] == '='
  let key_end = index
  let value_start = if colon_assign { index + 2 } else { index + 1 }
  let is_json = colon_assign
  let key = pair.exact_view(end=key_end).to_owned()
  if key.length() == 0 {
    raise fail("'" + pair + "' has an empty key")
  }
  (key, pair.exact_view(start=value_start).to_owned(), is_json)
}

///|
/// Build the `arguments` object for a tool call.
pub fn build_arguments(
  pairs : Array[String],
  schema : Json,
) -> Json raise McpError {
  let properties = schema_properties(schema)
  let fields : Map[String, Json] = Map([])
  for pair in pairs {
    let (key, raw, is_json) = split_argument(pair)
    fields[key] = if is_json {
      parse_jsonc(raw)
    } else {
      coerce_value(raw, properties.get(key))
    }
  }
  Json::object(fields)
}

///|
/// The JSON view of a server's `initialize` result.
pub fn server_info_to_json(info : ServerInfo) -> Json {
  let fields : Map[String, Json] = {
    "name": Json::string(info.name),
    "version": Json::string(info.version),
    "protocolVersion": Json::string(info.protocol_version),
  }
  if info.instructions.length() > 0 {
    fields["instructions"] = Json::string(info.instructions)
  }
  Json::object(fields)
}

///|
/// The names-only discovery view. This path never connects to a server.
fn render_server_names(servers : Array[Server]) -> String {
  let names : Array[String] = []
  for server in servers {
    names.push(server.name)
  }
  names.join("\n")
}

///|
/// The JSON view of configured servers without contacting any of them.
fn render_servers_json(servers : Array[Server]) -> String {
  let items : Array[Json] = []
  for server in servers {
    items.push(server_to_json(server))
  }
  Json::object({ "servers": Json::array(items) }).stringify(indent=2)
}

///|
/// Render the `mcpbox list` result as JSON.
fn render_reports_json(reports : Array[ServerReport]) -> String {
  let servers : Array[Json] = []
  for report in reports {
    let fields : Map[String, Json] = match server_to_json(report.server) {
      Object(obj) => obj
      _ => Map([])
    }
    match report.info {
      Some(info) => fields["serverInfo"] = server_info_to_json(info)
      None => ()
    }
    match report.error {
      Some(message) => fields["error"] = Json::string(message)
      None => ()
    }
    let tools : Array[Json] = []
    for tool in report.tools {
      tools.push(tool_to_json(tool))
    }
    fields["tools"] = Json::array(tools)
    servers.push(Json::object(fields))
  }
  Json::object({ "servers": Json::array(servers) }).stringify(indent=2)
}

///|
/// Render the `mcpbox list` result for a human.
fn render_reports_text(reports : Array[ServerReport], opts : Options) -> String {
  let out = StringBuilder()
  let mut first = true
  for report in reports {
    if !first {
      out.write_string("\n")
    }
    first = false
    if opts.brief {
      out.write_string("\{report.server.name}  ")
      match report.error {
        Some(message) => out.write_string("error: " + message)
        None => out.write_string("(\{report.tools.length()} tools)")
      }
      continue
    }
    out.write_string(
      "\{report.server.name}  \{transport_target(report.server)}",
    )
    match report.info {
      Some(info) =>
        if info.name.length() > 0 || info.version.length() > 0 {
          out.write_string("  [\{info.name} \{info.version}]")
        }
      None => ()
    }
    out.write_string("\n")
    if !opts.no_docs {
      match report.info {
        Some(info) =>
          for line in render_instructions(info.instructions, "  ") {
            out.write_string(line + "\n")
          }
        None => ()
      }
    }
    match report.error {
      Some(message) => out.write_string("  error: " + message + "\n")
      None =>
        if report.tools.length() == 0 {
          out.write_string("  (no tools)\n")
        } else {
          let mut first_tool = true
          for tool in report.tools {
            if !first_tool && !opts.no_docs {
              out.write_string("\n")
            }
            first_tool = false
            if !opts.no_docs {
              for line in render_tool_doc(tool, "  ") {
                out.write_string(line + "\n")
              }
            }
            out.write_string("  " + render_tool_signature(tool) + "\n")
          }
        }
    }
  }
  out.to_string()
}

///|
/// Render a tool call result according to the output flags.
fn render_call_output(result : CallResult, opts : Options) -> String {
  if opts.json {
    return call_result_to_json(result).stringify()
  }
  if opts.raw {
    let out = StringBuilder()
    for block in result.content {
      match block {
        Text(text) => out.write_string(text)
        _ => ()
      }
    }
    return out.to_string()
  }
  render_call_result(result)
}
