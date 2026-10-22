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
/// Target width of a tool doc comment, including indentation and markers.
/// An unbroken word may exceed this width.
const DOC_WIDTH : Int32 = 80

///|
/// Split `text` into words, treating any run of whitespace as one separator.
fn doc_words(text : String) -> Array[String] {
  let cleaned = StringBuilder()
  for c in text.to_array() {
    if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
      cleaned.write_char(' ')
    } else {
      cleaned.write_char(c)
    }
  }
  let out : Array[String] = []
  for raw in cleaned.to_string().split(" ") {
    let word = raw.to_owned()
    if word.length() > 0 {
      out.push(word)
    }
  }
  out
}

///|
/// Greedily wrap `text` into lines of at most `width` characters.
fn wrap_doc(text : String, width : Int32) -> Array[String] {
  let lines : Array[String] = []
  let current = StringBuilder()
  let mut empty = true
  for word in doc_words(text) {
    if empty {
      current.write_string(word)
      empty = false
    } else if current.to_string().length() + 1 + word.length() <= width {
      current.write_string(" ")
      current.write_string(word)
    } else {
      lines.push(current.to_string())
      current.reset()
      current.write_string(word)
    }
  }
  if !empty {
    lines.push(current.to_string())
  }
  lines
}

///|
/// The `description` of a schema node, if it has one.
pub fn schema_description(schema : Json) -> String {
  match schema {
    Object(obj) =>
      match obj.get("description") {
        Some(String(text)) => text
        _ => ""
      }
    _ => ""
  }
}

///|
/// A JSON value as a short bare word: strings lose their quotes.
fn bare_value(value : Json) -> String {
  match value {
    String(text) => text
    _ => value.stringify()
  }
}

///|
/// The allowed values of an `enum` schema, comma separated.
pub fn schema_choices(schema : Json) -> String {
  match schema {
    Object(obj) =>
      match obj.get("enum") {
        Some(Array(items)) => {
          let parts : Array[String] = []
          for item in items {
            parts.push(bare_value(item))
          }
          parts.join(", ")
        }
        _ => ""
      }
    _ => ""
  }
}

///|
/// The prose attached to a parameter: its description, then the choices and
/// default so a caller can see the whole contract of the argument.
fn param_doc(schema : Json) -> String {
  let parts : Array[String] = []
  let description = schema_description(schema).trim().to_owned()
  if description.length() > 0 {
    parts.push(description)
  }
  let choices = schema_choices(schema)
  if choices.length() > 0 {
    parts.push("choices: " + choices)
  }
  match schema {
    Object(obj) =>
      match obj.get("default") {
        Some(value) => parts.push("default: " + bare_value(value))
        None => ()
      }
    _ => ()
  }
  parts.join("; ")
}

///|
/// A JSDoc-style comment for a tool: the description, then one `@param` line
/// per documented argument. This is the shape a TypeScript MCP client shows,
/// and it turns a bare signature into something a reader can act on. Tools
/// with nothing to say render no lines at all.
pub fn render_tool_doc(tool : Tool, indent : String) -> Array[String] {
  let lines : Array[String] = []
  let description = tool.description.trim().to_owned()
  let properties = schema_properties(tool.input_schema)
  let required = required_names(tool.input_schema)
  let names = Array::from_iter(properties.keys())
  names.sort_by((a, b) => a.lexical_compare(b))
  let documented : Array[String] = []
  let texts : Array[String] = []
  for name in names {
    let text = param_doc(properties.get(name).unwrap_or(Json::null()))
    if text.length() > 0 {
      documented.push(name)
      texts.push(text)
    }
  }
  if description.length() == 0 && documented.length() == 0 {
    return lines
  }
  let available = DOC_WIDTH - indent.length() - 3
  let width = if available > 0 { available } else { 1 }
  lines.push(indent + "/**")
  for line in wrap_doc(description, width) {
    lines.push(indent + " * " + line)
  }
  if description.length() > 0 && documented.length() > 0 {
    lines.push(indent + " *")
  }
  for i in 0..<documented.length() {
    let label = "@param " +
      documented[i] +
      (if required.contains(documented[i]) { "" } else { "?" })
    let pad = " ".repeat(label.length() + 1)
    let mut first = true
    for line in wrap_doc(texts[i], width - label.length() - 1) {
      if first {
        lines.push(indent + " * " + label + " " + line)
        first = false
      } else {
        lines.push(indent + " * " + pad + line)
      }
    }
  }
  lines.push(indent + " */")
  lines
}

///|
/// A server's `instructions` clipped to one readable line, or no lines when it
/// sent none.
pub fn render_instructions(text : String, indent : String) -> Array[String] {
  let normalized = doc_words(text).join(" ")
  if normalized.length() == 0 {
    return []
  }
  let chars = normalized.to_array()
  let clipped = if chars.length() > 500 {
    let out = StringBuilder()
    for i in 0..<499 {
      out.write_char(chars[i])
    }
    out.write_string("…")
    out.to_string()
  } else {
    normalized
  }
  [indent + "Instructions: " + clipped]
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
