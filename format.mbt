///|
/// Output rendering: compact tool signatures for humans and stable JSON for
/// scripts. Nothing here does I/O, which keeps it easy to test.

///|
/// The JSON Schema type of a property, rendered for a signature.
pub fn schema_type(schema : Json) -> String {
  match schema {
    Object(obj) =>
      match obj.get("type") {
        Some(String(name)) => name
        Some(Array(types)) => {
          let parts : Array[String] = []
          for item in types {
            match item {
              String(name) => parts.push(name)
              _ => ()
            }
          }
          if parts.length() == 0 {
            "any"
          } else {
            parts.join(" | ")
          }
        }
        _ =>
          match obj.get("enum") {
            Some(Array(_)) => "enum"
            _ => "any"
          }
      }
    _ => "any"
  }
}

///|
/// The `required` list of a tool schema.
fn required_names(schema : Json) -> Array[String] {
  let out : Array[String] = []
  match schema {
    Object(obj) =>
      match obj.get("required") {
        Some(Array(items)) =>
          for item in items {
            match item {
              String(name) => out.push(name)
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// The `properties` map of a tool schema, if any.
pub fn schema_properties(schema : Json) -> Map[String, Json] {
  match schema {
    Object(obj) =>
      match obj.get("properties") {
        Some(Object(props)) => props
        _ => Map([])
      }
    _ => Map([])
  }
}

///|
/// Render a tool's parameters as `name: type, optional?: type`, with the names
/// sorted so the output is stable across runs.
pub fn render_params(schema : Json) -> String {
  let properties = schema_properties(schema)
  if properties.is_empty() {
    return ""
  }
  let required = required_names(schema)
  // `String::compare` orders by length first, which makes a parameter list
  // look arbitrary; lexical order is what a reader expects.
  let names = Array::from_iter(properties.keys())
  names.sort_by((a, b) => a.lexical_compare(b))
  let parts : Array[String] = []
  for name in names {
    let optional = !required.contains(name)
    let type_name = schema_type(properties.get(name).unwrap_or(Json::null()))
    parts.push(name + (if optional { "?" } else { "" }) + ": " + type_name)
  }
  parts.join(", ")
}

///|
/// A one-line signature for a tool: `name(params)`.
pub fn render_tool_signature(tool : Tool) -> String {
  "\{tool.name}(\{render_params(tool.input_schema)})"
}

///|
/// The first line of a description, so a table stays one line per tool.
pub fn first_line(text : String) -> String {
  match text.split_once("\n") {
    Some((line, _)) => line.trim().to_owned()
    None => text.trim().to_owned()
  }
}

///|
/// A short transport label, e.g. `http` or `stdio`.
pub fn transport_label(server : Server) -> String {
  match server.kind {
    Stdio(_) => "stdio"
    Http(_) => "http"
  }
}

///|
/// Where a server connects to, for a listing.
pub fn transport_target(server : Server) -> String {
  match server.kind {
    Stdio(spec) =>
      if spec.args.length() == 0 {
        spec.command
      } else {
        spec.command + " " + spec.args.join(" ")
      }
    Http(spec) => spec.url
  }
}

///|
/// The JSON view of a tool.
pub fn tool_to_json(tool : Tool) -> Json {
  let fields : Map[String, Json] = {
    "name": Json::string(tool.name),
    "description": Json::string(tool.description),
    "inputSchema": tool.input_schema,
  }
  if tool.title.length() > 0 {
    fields["title"] = Json::string(tool.title)
  }
  Json::object(fields)
}

///|
/// The JSON view of a server definition.
pub fn server_to_json(server : Server) -> Json {
  let fields : Map[String, Json] = {
    "name": Json::string(server.name),
    "transport": Json::string(transport_label(server)),
    "target": Json::string(transport_target(server)),
    "note": Json::string(server.note),
  }
  match server.kind {
    Stdio(spec) =>
      if spec.cwd.length() > 0 {
        fields["cwd"] = Json::string(spec.cwd)
      }
    Http(_) => ()
  }
  Json::object(fields)
}

///|
/// The JSON view of one content block, in the shape MCP uses.
pub fn content_to_json(content : Content) -> Json {
  match content {
    Text(text) =>
      Json::object({ "type": Json::string("text"), "text": Json::string(text) })
    Image(mime_type, data) =>
      Json::object({
        "type": Json::string("image"),
        "mimeType": Json::string(mime_type),
        "data": Json::string(data),
      })
    Audio(mime_type, data) =>
      Json::object({
        "type": Json::string("audio"),
        "mimeType": Json::string(mime_type),
        "data": Json::string(data),
      })
    EmbeddedResource(resource) =>
      Json::object({ "type": Json::string("resource"), "resource": resource })
    Unknown(raw) => raw
  }
}

///|
/// The JSON view of a tool call result.
pub fn call_result_to_json(result : CallResult) -> Json {
  let content : Array[Json] = []
  for block in result.content {
    content.push(content_to_json(block))
  }
  let fields : Map[String, Json] = {
    "content": Json::array(content),
    "isError": Json::boolean(result.is_error),
  }
  match result.structured {
    Some(structured) => fields["structuredContent"] = structured
    None => ()
  }
  Json::object(fields)
}

///|
/// The text a human sees for a tool call: the text blocks joined, images and
/// audio summarised, and structured content printed as JSON.
pub fn render_call_result(result : CallResult) -> String {
  let out = StringBuilder()
  let mut wrote = false
  for block in result.content {
    match block {
      Text(text) => {
        if wrote {
          out.write_string("\n")
        }
        out.write_string(text)
        wrote = true
      }
      Image(mime_type, data) => {
        if wrote {
          out.write_string("\n")
        }
        out.write_string(
          "[image \{mime_type}, \{data.length()} base64 characters]",
        )
        wrote = true
      }
      Audio(mime_type, data) => {
        if wrote {
          out.write_string("\n")
        }
        out.write_string(
          "[audio \{mime_type}, \{data.length()} base64 characters]",
        )
        wrote = true
      }
      EmbeddedResource(resource) => {
        if wrote {
          out.write_string("\n")
        }
        out.write_string("[resource] " + resource.stringify())
        wrote = true
      }
      Unknown(raw) => {
        if wrote {
          out.write_string("\n")
        }
        out.write_string(raw.stringify())
        wrote = true
      }
    }
  }
  match result.structured {
    Some(structured) => {
      if wrote {
        out.write_string("\n")
      }
      out.write_string(structured.stringify(indent=2))
    }
    None => ()
  }
  out.to_string()
}
