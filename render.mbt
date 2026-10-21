///|
/// Turning parsed results into the text or JSON a caller sees, plus the
/// schema-aware coercion that makes `key=value` arguments pleasant to write.

///|
/// Parse an integer, or `None` when the text is not one.
fn try_int(raw : String) -> Int32? {
  Some(@string.parse_int(raw.trim())) catch {
    _ => None
  }
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
          match try_int(raw) {
            Some(value) =>
              Json::number(value.to_double(), repr=value.to_string())
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
/// Build the `arguments` object for a tool call.
pub fn build_arguments(
  pairs : Array[String],
  schema : Json,
) -> Json raise McpError {
  let properties = schema_properties(schema)
  let fields : Map[String, Json] = Map([])
  for pair in pairs {
    match pair.find(":=") {
      Some(index) => {
        let key = pair.exact_view(end=index).to_owned()
        let raw = pair.exact_view(start=index + 2).to_owned()
        if key.length() == 0 {
          raise fail("'" + pair + "' has an empty key")
        }
        fields[key] = parse_jsonc(raw)
      }
      None =>
        match pair.find("=") {
          Some(index) => {
            let key = pair.exact_view(end=index).to_owned()
            let raw = pair.exact_view(start=index + 1).to_owned()
            if key.length() == 0 {
              raise fail("'" + pair + "' has an empty key")
            }
            fields[key] = coerce_value(raw, properties.get(key))
          }
          None => raise fail("'" + pair + "' is not a key=value argument")
        }
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
    match report.error {
      Some(message) => out.write_string("  error: " + message + "\n")
      None =>
        if report.tools.length() == 0 {
          out.write_string("  (no tools)\n")
        } else {
          for tool in report.tools {
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
