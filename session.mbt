///|
/// The MCP client itself: one `Session` per connected server, speaking
/// JSON-RPC over either a stdio child process or a Streamable HTTP endpoint.
///
/// A session is created with `with_server`, which owns the transport for the
/// lifetime of the callback. That keeps process cleanup and HTTP session
/// teardown in one place, and lets `mcpbox list` fan out over servers with
/// structured concurrency.
///
/// The async functions here raise the base `Error`: the transports underneath
/// can fail with anything the runtime produces, and the CLI reports whatever
/// message arrives. The pure parsers below keep the narrower `McpError`.

///|
/// A live, initialized MCP session.
pub struct Session {
  priv name : String
  priv mut next_id : Int
  priv link : Link
  priv mut info : ServerInfo
}

///|
/// The transport behind a session.
priv enum Link {
  Stdio(StdioLink)
  Http(HttpLink)
}

///|
/// A stdio child process plus the tail of its standard error, kept for
/// diagnostics when the handshake or a call fails.
priv struct StdioLink {
  stdin : @process.WriteToProcess
  stdout : @process.ReadFromProcess
  stderr_log : Array[String]
}

///|
/// A Streamable HTTP endpoint and the session id the server handed back.
priv struct HttpLink {
  url : String
  headers : Map[String, String]
  mut session_id : String?
}

///|
/// The server's name, for messages.
pub fn Session::name(self : Session) -> String {
  self.name
}

///|
/// What the server reported during `initialize`.
pub fn Session::server_info(self : Session) -> ServerInfo {
  self.info
}

///|
/// Build a session around an already-connected transport.
fn Session::connect(name : String, link : Link) -> Session {
  {
    name,
    next_id: 1,
    link,
    info: { name: "", version: "", protocol_version: "", instructions: "", },
  }
}

///|
/// Connect to a server, run the `initialize` handshake, hand the session to
/// `f`, and tear the transport down again. The server's child process is owned
/// by the enclosing task group, so an error anywhere still reaps it.
pub async fn with_server(
  server : Server,
  timeout_ms : Int,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  match server.kind {
    Stdio(spec) => with_stdio_session(server.name, spec, timeout_ms, f)
    Http(spec) => with_http_session(server.name, spec, timeout_ms, f)
  }
}

///|
/// Spawn the child process, wire up its pipes, and keep a bounded tail of its
/// stderr so a crash has something to say for itself.
async fn with_stdio_session(
  name : String,
  spec : StdioSpec,
  timeout_ms : Int,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  @async.with_task_group(group => {
    let (stdin_pipe, stdin_writer) = @process.write_to_process() catch {
      e => raise fail("cannot create a pipe for '\{name}': \{e.to_string()}")
    }
    let (stdout_reader, stdout_pipe) = @process.read_from_process() catch {
      e => raise fail("cannot create a pipe for '\{name}': \{e.to_string()}")
    }
    let (stderr_reader, stderr_pipe) = @process.read_from_process() catch {
      e => raise fail("cannot create a pipe for '\{name}': \{e.to_string()}")
    }
    let cwd : StringView? = if spec.cwd.length() > 0 {
      Some(spec.cwd)
    } else {
      None
    }
    let _process = @process.spawn(
      group,
      spec.command,
      spec.args,
      extra_env=spec.env,
      stdin=stdin_pipe,
      stdout=stdout_pipe,
      stderr=stderr_pipe,
      cwd?,
      no_wait=true,
    ) catch {
      e => raise fail("cannot start '\{name}': \{e.to_string()}")
    }
    let stderr_log : Array[String] = []
    group.spawn_bg(no_wait=true, () => {
      let mut running = true
      while running {
        match stderr_reader.read_until("\n") {
          None => running = false
          Some(line) => {
            let text = line.trim().to_owned()
            if text.length() > 0 {
              if stderr_log.length() >= 20 {
                ignore(stderr_log.remove(0))
              }
              stderr_log.push(text)
            }
          }
        }
      }
    })
    let link = { stdin: stdin_writer, stdout: stdout_reader, stderr_log, }
    let session = Session::connect(name, Link::Stdio(link))
    session.initialize(timeout_ms)
    f(session)
    session.close()
  })
}

///|
/// Connect over Streamable HTTP. There is no child process to manage, so the
/// session is closed with a best-effort `DELETE`.
async fn with_http_session(
  name : String,
  spec : HttpSpec,
  timeout_ms : Int,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  let link = { url: spec.url, headers: spec.headers, session_id: None, }
  let session = Session::connect(name, Link::Http(link))
  session.initialize(timeout_ms)
  f(session)
  session.close()
}

///|
/// Run the MCP `initialize` handshake and the `initialized` notification.
async fn Session::initialize(
  self : Session,
  timeout_ms : Int,
) -> Unit raise Error {
  let params = Json::object({
    "protocolVersion": Json::string(protocol_version),
    "capabilities": Json::object(Map([])),
    "clientInfo": Json::object({
      "name": Json::string("mcpbox"),
      "version": Json::string(version),
    }),
  })
  let result = self.request("initialize", Some(params), timeout_ms)
  self.info = parse_server_info(result)
  self.notify("notifications/initialized", None, timeout_ms)
}

///|
/// Pull the `serverInfo` block out of an `initialize` result.
fn parse_server_info(result : Json) -> ServerInfo {
  let empty : ServerInfo = {
    name: "",
    version: "",
    protocol_version: "",
    instructions: "",
  }
  match result {
    Object(obj) => {
      let server_info = match obj.get("serverInfo") {
        Some(Object(si)) => si
        _ => Map([])
      }
      {
        name: match server_info.get("name") {
          Some(String(s)) => s
          _ => ""
        },
        version: match server_info.get("version") {
          Some(String(s)) => s
          _ => ""
        },
        protocol_version: match obj.get("protocolVersion") {
          Some(String(s)) => s
          _ => ""
        },
        instructions: match obj.get("instructions") {
          Some(String(s)) => s
          _ => ""
        },
      }
    }
    _ => empty
  }
}

///|
/// Send a request and wait for its response, answering server requests and
/// skipping notifications along the way.
async fn Session::request(
  self : Session,
  rpc_method : String,
  params : Json?,
  timeout_ms : Int,
) -> Json raise Error {
  let id = self.next_id
  self.next_id = self.next_id + 1
  let message = rpc_request(id, rpc_method, params)
  match self.link {
    Stdio(link) => {
      write_line(link, message, self.name, timeout_ms)
      let mut outcome : Json? = None
      while outcome is None {
        match read_message(link, self.name, timeout_ms) {
          Response(response_id, result, error) =>
            if response_id == id {
              match error {
                Some(e) => raise fail("\{self.name}: \{e.message}")
                None => outcome = Some(result.unwrap_or(Json::null()))
              }
            }
          ServerRequest(server_id, method_name, _) =>
            write_line(
              link,
              rpc_error_response(
                server_id,
                -32601,
                "mcpbox does not implement '\{method_name}'",
              ),
              self.name,
              timeout_ms,
            )
          Notification(_, _) => ()
        }
      }
      outcome.unwrap()
    }
    Http(link) => http_request(link, message, id, self.name, timeout_ms)
  }
}

///|
/// Send a notification. Failures are real errors: a server that never learns
/// the session is initialized will reject every later request.
async fn Session::notify(
  self : Session,
  rpc_method : String,
  params : Json?,
  timeout_ms : Int,
) -> Unit raise Error {
  let message = rpc_notification(rpc_method, params)
  match self.link {
    Stdio(link) => write_line(link, message, self.name, timeout_ms)
    Http(link) => ignore(http_post(link, message, self.name, timeout_ms))
  }
}

///|
/// List the server's tools.
pub async fn Session::list_tools(
  self : Session,
  timeout_ms : Int,
) -> Array[Tool] raise Error {
  let result = self.request(
    "tools/list",
    Some(Json::object(Map([]))),
    timeout_ms,
  )
  parse_tools(result)
}

///|
/// Call one tool. `arguments` is the already-built JSON object.
pub async fn Session::call_tool(
  self : Session,
  name : String,
  arguments : Json,
  timeout_ms : Int,
) -> CallResult raise Error {
  let params = Json::object({
    "name": Json::string(name),
    "arguments": arguments,
  })
  let result = self.request("tools/call", Some(params), timeout_ms)
  parse_call_result(result)
}

///|
/// Close the transport. For stdio this closes the child's stdin, which is the
/// MCP shutdown signal; the task group reaps the process afterwards. For HTTP
/// it asks the server to drop the session, best effort: a failed cleanup must
/// not turn a successful call into an error.
async fn Session::close(self : Session) -> Unit {
  match self.link {
    Stdio(link) => link.stdin.close()
    Http(link) =>
      match link.session_id {
        None => ()
        Some(session_id) => {
          let headers : Map[@http.CaseInsensitiveString, String] = Map([])
          headers[@http.CaseInsensitiveString("mcp-session-id")] = session_id
          ignore(
            @async.with_timeout_opt(5000, () => {
              @http.request(link.url, @http.Delete, headers, "")
            }),
          ) catch {
            _ => ()
          }
        }
      }
  }
}

///|
/// Decode a `tools/list` result.
pub fn parse_tools(result : Json) -> Array[Tool] raise McpError {
  guard result is Object(obj) else {
    raise fail("tools/list did not return an object")
  }
  let out : Array[Tool] = []
  match obj.get("tools") {
    Some(Array(tools)) =>
      for tool in tools {
        out.push(parse_tool(tool))
      }
    Some(_) => raise fail("tools/list returned a non-array 'tools' field")
    None => ()
  }
  out
}

///|
/// Decode one tool descriptor, tolerating servers that omit optional fields.
pub fn parse_tool(json : Json) -> Tool raise McpError {
  guard json is Object(obj) else {
    raise fail("a tool descriptor was not an object")
  }
  let name = match obj.get("name") {
    Some(String(s)) => s
    _ => raise fail("a tool descriptor had no 'name'")
  }
  {
    name,
    title: match obj.get("title") {
      Some(String(s)) => s
      _ => ""
    },
    description: match obj.get("description") {
      Some(String(s)) => s
      _ => ""
    },
    input_schema: obj.get("inputSchema").unwrap_or(Json::object(Map([]))),
  }
}

///|
/// Decode a `tools/call` result.
pub fn parse_call_result(result : Json) -> CallResult raise McpError {
  guard result is Object(obj) else {
    raise fail("tools/call did not return an object")
  }
  let content : Array[Content] = []
  match obj.get("content") {
    Some(Array(items)) =>
      for item in items {
        content.push(parse_content(item))
      }
    _ => ()
  }
  {
    content,
    is_error: match obj.get("isError") {
      Some(True) => true
      _ => false
    },
    structured: obj.get("structuredContent"),
  }
}

///|
/// Decode one content block.
pub fn parse_content(json : Json) -> Content {
  match json {
    Object(obj) =>
      match obj.get("type") {
        Some(String("text")) =>
          match obj.get("text") {
            Some(String(text)) => Text(text)
            _ => Unknown(json)
          }
        Some(String("image")) =>
          match (obj.get("mimeType"), obj.get("data")) {
            (Some(String(mime)), Some(String(data))) => Image(mime, data)
            _ => Unknown(json)
          }
        Some(String("audio")) =>
          match (obj.get("mimeType"), obj.get("data")) {
            (Some(String(mime)), Some(String(data))) => Audio(mime, data)
            _ => Unknown(json)
          }
        Some(String("resource")) => EmbeddedResource(json)
        _ => Unknown(json)
      }
    _ => Unknown(json)
  }
}

///|
/// Write one JSON-RPC message as a newline-delimited frame.
async fn write_line(
  link : StdioLink,
  message : Json,
  name : String,
  timeout_ms : Int,
) -> Unit raise Error {
  let line = message.stringify() + "\n"
  @async.with_timeout(
    timeout_ms,
    () => link.stdin.write(line),
    error=fail("timed out after \{timeout_ms}ms writing to '\{name}'"),
  ) catch {
    e => raise fail("cannot write to '\{name}': \{e.to_string()}")
  }
}

///|
/// Read one message, skipping blank lines and values that are not JSON-RPC.
async fn read_message(
  link : StdioLink,
  name : String,
  timeout_ms : Int,
) -> RpcMessage raise Error {
  let mut outcome : RpcMessage? = None
  while outcome is None {
    let line = @async.with_timeout(
      timeout_ms,
      () => link.stdout.read_until("\n"),
      error=fail("timed out after \{timeout_ms}ms waiting for '\{name}'"),
    ) catch {
      e => raise fail("cannot read from '\{name}': \{e.to_string()}")
    }
    match line {
      None =>
        raise fail(
          "'\{name}' closed its output before answering\{stderr_hint(link)}",
        )
      Some(text) => {
        let trimmed = text.trim().to_owned()
        if trimmed.length() == 0 {
          continue
        }
        let json = @json.parse(trimmed) catch {
          e => raise fail("'\{name}' sent invalid JSON: \{e.to_string()}")
        }
        outcome = decode_rpc_message(json)
      }
    }
  }
  outcome.unwrap()
}

///|
/// A trailing hint built from the child's last stderr lines.
fn stderr_hint(link : StdioLink) -> String {
  if link.stderr_log.length() == 0 {
    return ""
  }
  let out = StringBuilder()
  out.write_string(" (stderr: ")
  let mut first = true
  for line in link.stderr_log {
    if !first {
      out.write_string("; ")
    }
    first = false
    out.write_string(line)
  }
  out.write_string(")")
  out.to_string()
}

///|
/// POST one message and return the decoded JSON-RPC result. Handles both
/// `application/json` and the `text/event-stream` framing servers may choose
/// for a Streamable HTTP response.
async fn http_request(
  link : HttpLink,
  message : Json,
  id : Int,
  name : String,
  timeout_ms : Int,
) -> Json raise Error {
  let (code, body) = http_post(link, message, name, timeout_ms)
  if code >= 400 {
    raise fail("'\{name}' returned HTTP \{code}: \{body}")
  }
  let payload = extract_sse(body)
  if payload.length() == 0 {
    raise fail("'\{name}' returned an empty response")
  }
  let json = @json.parse(payload) catch {
    e => raise fail("'\{name}' returned invalid JSON: \{e.to_string()}")
  }
  match find_response(json, id) {
    Some(Ok(result)) => result
    Some(Err(error)) => raise fail("\{name}: \{error.message}")
    None => raise fail("'\{name}' did not return a response to request \{id}")
  }
}

///|
/// POST one message, returning the HTTP status and the response text.
async fn http_post(
  link : HttpLink,
  message : Json,
  name : String,
  timeout_ms : Int,
) -> (Int, String) raise Error {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("content-type")] = "application/json"
  headers[@http.CaseInsensitiveString("accept")] = "application/json, text/event-stream"
  for entry in link.headers {
    headers[@http.CaseInsensitiveString(entry.0)] = entry.1
  }
  match link.session_id {
    Some(session_id) =>
      headers[@http.CaseInsensitiveString("mcp-session-id")] = session_id
    None => ()
  }
  // The convenience `@http.post` treats its headers as *client* headers, where
  // `Content-Length` is forbidden, so it always frames the body with
  // `Transfer-Encoding: chunked` — which some minimal servers and proxies
  // refuse. Driving the client directly puts `Content-Length` in the
  // per-request headers, where the library honours it and sends a fixed-length
  // body every server understands.
  let body = message.stringify()
  headers[@http.CaseInsensitiveString("content-length")] = body
    .length()
    .to_string()
  let (origin, path) = split_url(link.url)
  let (response, data) = @async.with_timeout(
    timeout_ms,
    () => {
      let client = @http.Client::Client(origin)
      defer client.close()
      let response = client
        ..request(@http.Post, path, extra_headers=headers)
        ..write(body)
        .end_request()
      (response, client.read_all())
    },
    error=fail("timed out after \{timeout_ms}ms calling '\{name}'"),
  ) catch {
    e => raise fail("cannot reach '\{name}': \{e.to_string()}")
  }
  match response.headers.get(@http.CaseInsensitiveString("mcp-session-id")) {
    Some(session_id) => link.session_id = Some(session_id)
    None => ()
  }
  let text = data.text() catch {
    e => raise fail("cannot read the response from '\{name}': \{e.to_string()}")
  }
  (response.code, text)
}

///|
/// Split a URL into an origin the HTTP client accepts (`Client::Client`
/// requires the path to be `/`) and the request path. `https://h:1/mcp`
/// becomes `("https://h:1/", "/mcp")`.
fn split_url(url : String) -> (String, String) {
  let scheme_end = match url.find("://") {
    Some(index) => index + 3
    None => 0
  }
  let rest = url[scheme_end:]
  match rest.find("/") {
    Some(index) =>
      (
        url.exact_view(end=scheme_end + index).to_owned() + "/",
        rest[index:].to_owned(),
      )
    None => (url + "/", "/")
  }
}

///|
/// Collapse a `text/event-stream` body into the JSON payload it carries. A
/// plain JSON body is returned unchanged.
fn extract_sse(body : String) -> String {
  if !body.contains("data:") {
    return body.trim().to_owned()
  }
  let out = StringBuilder()
  for line in body.split("\n") {
    let trimmed = line.trim()
    if trimmed.has_prefix("data:") {
      match trimmed.strip_prefix("data:") {
        Some(rest) => out.write_string(rest.trim().to_owned())
        None => ()
      }
    }
  }
  out.to_string()
}

///|
/// Find the response with a matching id inside a single object or a batch.
fn find_response(
  json : Json,
  id : Int,
) -> Result[Json, RpcError]? raise McpError {
  match json {
    Array(items) => {
      for item in items {
        match decode_rpc_message(item) {
          Some(Response(response_id, result, error)) =>
            if response_id == id {
              match error {
                Some(e) => return Some(Err(e))
                None => return Some(Ok(result.unwrap_or(Json::null())))
              }
            }
          _ => ()
        }
      }
      None
    }
    _ =>
      match decode_rpc_message(json) {
        Some(Response(response_id, result, error)) =>
          if response_id == id {
            match error {
              Some(e) => Some(Err(e))
              None => Some(Ok(result.unwrap_or(Json::null())))
            }
          } else {
            None
          }
        _ => None
      }
  }
}
