///|
/// The MCP client itself: one `Session` per connected server, speaking
/// JSON-RPC over a stdio child process, a Streamable HTTP endpoint, or the
/// legacy HTTP+SSE transport.
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
  priv mut next_id : Int32
  priv link : Link
  priv mut info : ServerInfo
}

///|
/// The transport behind a session.
priv enum Link {
  Stdio(StdioLink)
  Http(HttpLink)
  Sse(SseLink)
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
/// A legacy HTTP+SSE connection: the long-lived `GET` stream, the endpoint its
/// `endpoint` event named for `POST`ed messages, and the static headers to send
/// with both. `last_event_id` is replayed as `Last-Event-ID` after a drop so a
/// server that supports resumption can resend missed events.
priv struct SseLink {
  url : String
  headers : Map[String, String]
  mut client : @http.Client
  mut endpoint : String
  mut last_event_id : String
}

///|
/// How many times one pending request may reconnect after the event stream
/// drops before giving up. The request itself is never re-sent.
const SSE_MAX_RECONNECTS : Int32 = 3

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
  timeout_ms : Int32,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  match server.kind {
    Stdio(spec) => with_stdio_session(server.name, spec, timeout_ms, f)
    Http(spec) => with_http_session(server.name, spec, timeout_ms, f)
    Sse(spec) => with_sse_session(server.name, spec, timeout_ms, f)
  }
}

///|
/// Spawn the child process, wire up its pipes, and keep a bounded tail of its
/// stderr so a crash has something to say for itself.
async fn with_stdio_session(
  name : String,
  spec : StdioSpec,
  timeout_ms : Int32,
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
  timeout_ms : Int32,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  let link = { url: spec.url, headers: spec.headers, session_id: None, }
  let session = Session::connect(name, Link::Http(link))
  // A failed callback must still send the session-termination DELETE: there
  // is no task group here to reap the remote session the way it reaps a stdio
  // child, and leaking it would leave the server holding state per failed call.
  let outcome : Result[Unit, Error] = try {
    session.initialize(timeout_ms)
    f(session)
    Ok(())
  } catch {
    error => Err(error)
  }
  session.close()
  match outcome {
    Ok(_) => ()
    Err(error) => raise error
  }
}

///|
/// Connect over the legacy HTTP+SSE transport: open the event stream, wait for
/// the `endpoint` event, then let the session POST messages and read their
/// responses from the stream. Closing the session closes the stream.
async fn with_sse_session(
  name : String,
  spec : SseSpec,
  timeout_ms : Int32,
  f : async (Session) -> Unit raise Error,
) -> Unit raise Error {
  let link = sse_connect(spec.url, spec.headers, name, timeout_ms)
  let session = Session::connect(name, Link::Sse(link))
  let outcome : Result[Unit, Error] = try {
    session.initialize(timeout_ms)
    f(session)
    Ok(())
  } catch {
    error => Err(error)
  }
  session.close()
  match outcome {
    Ok(_) => ()
    Err(error) => raise error
  }
}

///|
/// A session that outlives the call that created it, for the resident daemon.
///
/// `with_server` ties a session to a callback so cleanup is automatic. The
/// daemon instead keeps one `LiveSession` per server between commands, which is
/// where the startup saving comes from: the child process is spawned once
/// rather than once per `mcpbox list` or `mcpbox call`.
///
/// A stdio child is started as an orphan, so it stays alive when the task that
/// spawned it returns. Shutdown closes stdin first, then escalates to signals
/// if the child does not exit voluntarily.
pub struct LiveSession {
  session : Session
  priv mut pid : Int32?
  priv mut closed : Bool
}

///|
/// The session inside, for listing tools and making calls.
pub fn LiveSession::session(self : LiveSession) -> Session {
  self.session
}

///|
/// Connect and handshake without owning the transport for a callback's
/// lifetime. The caller must eventually call `LiveSession::close`; the daemon
/// does so when a server is stopped.
pub async fn open_live_session(
  server : Server,
  timeout_ms : Int32,
  inherit_env~ : Bool = true,
) -> LiveSession raise Error {
  match server.kind {
    Sse(spec) => {
      let link = sse_connect(spec.url, spec.headers, server.name, timeout_ms)
      let session = Session::connect(server.name, Link::Sse(link))
      let outcome : Result[Unit, Error] = try {
        session.initialize(timeout_ms)
        Ok(())
      } catch {
        error => Err(error)
      }
      match outcome {
        Ok(_) => ()
        Err(error) => {
          session.close()
          raise error
        }
      }
      { session, pid: None, closed: false, }
    }
    Http(spec) => {
      let link = { url: spec.url, headers: spec.headers, session_id: None, }
      let session = Session::connect(server.name, Link::Http(link))
      let outcome : Result[Unit, Error] = try {
        session.initialize(timeout_ms)
        Ok(())
      } catch {
        error => Err(error)
      }
      match outcome {
        Ok(_) => ()
        Err(error) => {
          session.close()
          raise error
        }
      }
      { session, pid: None, closed: false, }
    }
    Stdio(spec) => {
      let (stdin_pipe, stdin_writer) = @process.write_to_process() catch {
        e =>
          raise fail(
            "cannot create a pipe for '\{server.name}': \{e.to_string()}",
          )
      }
      let (stdout_reader, stdout_pipe) = @process.read_from_process() catch {
        e => {
          stdin_writer.close()
          raise fail(
            "cannot create a pipe for '\{server.name}': \{e.to_string()}",
          )
        }
      }
      let cwd : StringView? = if spec.cwd.length() > 0 {
        Some(spec.cwd)
      } else {
        None
      }
      // Standard error is inherited, so it lands in the daemon's log file.
      // Giving the child a pipe nobody drains would eventually block it.
      let pid = @process.spawn_orphan(
        spec.command,
        spec.args,
        extra_env=spec.env,
        stdin=stdin_pipe,
        stdout=stdout_pipe,
        inherit_env~,
        cwd?,
      ) catch {
        e => {
          stdin_writer.close()
          stdout_reader.close()
          raise fail("cannot start '\{server.name}': \{e.to_string()}")
        }
      }
      let link = { stdin: stdin_writer, stdout: stdout_reader, stderr_log: [], }
      let session = Session::connect(server.name, Link::Stdio(link))
      let outcome : Result[Unit, Error] = try {
        session.initialize(timeout_ms)
        Ok(())
      } catch {
        e => Err(e)
      }
      match outcome {
        Ok(_) => { session, pid: Some(pid), closed: false, }
        Err(e) => {
          session.close()
          stdout_reader.close()
          reap_live_child(pid)
          raise e
        }
      }
    }
  }
}

///|
/// Tear the transport down and reap the child, escalating if it ignores EOF.
/// Calling this twice is harmless.
pub async fn LiveSession::close(self : LiveSession) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.session.close()
  match self.session.link {
    Stdio(link) => link.stdout.close()
    Http(_) | Sse(_) => ()
  }
  match self.pid {
    Some(pid) => {
      self.pid = None
      reap_live_child(pid)
    }
    None => ()
  }
}

///|
async fn reap_live_child(pid : Int32) -> Unit {
  let exited = @async.with_timeout_opt(3000, () => @process.wait_pid(pid)) catch {
    _ => Some(0)
  }
  if exited is Some(_) {
    return
  }
  mcpbox_signal_child(pid, 15)
  let terminated = @async.with_timeout_opt(1000, () => @process.wait_pid(pid)) catch {
    _ => Some(0)
  }
  if terminated is Some(_) {
    return
  }
  mcpbox_signal_child(pid, 9)
  ignore(@async.with_timeout_opt(1000, () => @process.wait_pid(pid))) catch {
    _ => ()
  }
}

///|
/// Run the MCP `initialize` handshake and the `initialized` notification.
async fn Session::initialize(
  self : Session,
  timeout_ms : Int32,
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
  timeout_ms : Int32,
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
    Sse(link) => sse_request(link, message, id, self.name, timeout_ms)
  }
}

///|
/// Send a notification. Failures are real errors: a server that never learns
/// the session is initialized will reject every later request.
async fn Session::notify(
  self : Session,
  rpc_method : String,
  params : Json?,
  timeout_ms : Int32,
) -> Unit raise Error {
  let message = rpc_notification(rpc_method, params)
  match self.link {
    Stdio(link) => write_line(link, message, self.name, timeout_ms)
    Sse(link) => sse_post(link, message, self.name, timeout_ms)
    Http(link) => {
      let (code, body) = http_exchange(
        link,
        @http.Post,
        link.url,
        message.stringify(),
        self.name,
        timeout_ms,
      )
      // A server that rejects `notifications/initialized` will refuse every
      // later request; reporting the status here says why.
      if code >= 400 {
        raise fail(
          "\{self.name} rejected \{rpc_method} with HTTP \{code}: \{body}",
        )
      }
    }
  }
}

///|
/// The cursor of a `tools/list` page, when the server paginates.
fn next_tools_cursor(result : Json) -> String? {
  guard result is Object(obj) else { return None }
  match obj.get("nextCursor") {
    Some(String(cursor)) if cursor.length() > 0 => Some(cursor)
    _ => None
  }
}

///|
/// List the server's tools, following `nextCursor` until the last page. A
/// server with more tools than fit in one response otherwise appears to be
/// missing everything after page one, and `call` reports a tool it does
/// advertise as unknown.
pub async fn Session::list_tools(
  self : Session,
  timeout_ms : Int32,
) -> Array[Tool] raise Error {
  let out : Array[Tool] = []
  let seen : Map[String, Unit] = Map([])
  let mut cursor : String? = None
  while true {
    let params = match cursor {
      None => Json::object(Map([]))
      Some(cursor) => Json::object({ "cursor": Json::string(cursor) })
    }
    let result = self.request("tools/list", Some(params), timeout_ms)
    for tool in parse_tools(result) {
      out.push(tool)
    }
    // A server that repeats a cursor would otherwise page forever.
    match next_tools_cursor(result) {
      None => break
      Some(next) =>
        if seen.contains(next) {
          break
        } else {
          seen[next] = ()
          cursor = Some(next)
        }
    }
  }
  out
}

///|
/// Call one tool. `arguments` is the already-built JSON object.
pub async fn Session::call_tool(
  self : Session,
  name : String,
  arguments : Json,
  timeout_ms : Int32,
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
        Some(_) =>
          ignore(
            @async.with_timeout_opt(5000, () => {
              http_exchange(link, @http.Delete, link.url, "", self.name, 5000)
            }),
          ) catch {
            _ => ()
          }
      }
    // Legacy SSE has no session-termination request: closing the event stream
    // is the shutdown signal.
    Sse(link) => link.client.close()
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
  timeout_ms : Int32,
) -> Unit raise Error {
  let line = message.stringify() + "\n"
  @async.with_timeout(
    timeout_ms,
    () => link.stdin.write(line),
    error=fail("timed out after \{timeout_ms}ms writing to '\{name}'"),
  ) catch {
    e => raise fail("cannot write to '\{name}': \{error_text(e)}")
  }
}

///|
/// Read one message, skipping blank lines and values that are not JSON-RPC.
async fn read_message(
  link : StdioLink,
  name : String,
  timeout_ms : Int32,
) -> RpcMessage raise Error {
  let mut outcome : RpcMessage? = None
  while outcome is None {
    let line = @async.with_timeout(
      timeout_ms,
      () => link.stdout.read_until("\n"),
      error=fail("timed out after \{timeout_ms}ms waiting for '\{name}'"),
    ) catch {
      e => raise fail("cannot read from '\{name}': \{error_text(e)}")
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
/// for a Streamable HTTP response. Several SSE events can precede the response
/// (notifications, keep-alives), so each event is decoded on its own instead of
/// being concatenated into one invalid JSON document.
async fn http_request(
  link : HttpLink,
  message : Json,
  id : Int32,
  name : String,
  timeout_ms : Int32,
) -> Json raise Error {
  let (code, body) = http_exchange(
    link,
    @http.Post,
    link.url,
    message.stringify(),
    name,
    timeout_ms,
  )
  if code >= 400 {
    raise fail("'\{name}' returned HTTP \{code}: \{body}")
  }
  if code >= 300 {
    // Redirects that can be followed were followed inside `http_exchange`, so
    // what remains here is an oddball status like `300` or `304 (no body)`,
    // whose body is not a JSON-RPC response.
    raise fail("'\{name}' returned HTTP \{code} instead of a response")
  }
  let payloads = sse_events(body)
  let mut parsed_any = false
  for payload in payloads {
    if payload.length() == 0 {
      continue
    }
    let json = @json.parse(payload) catch {
      e => raise fail("'\{name}' returned invalid JSON: \{e.to_string()}")
    }
    parsed_any = true
    match find_response(json, id) {
      Some(Ok(result)) => return result
      Some(Err(error)) => raise fail("\{name}: \{error.message}")
      None => ()
    }
  }
  if !parsed_any {
    raise fail("'\{name}' returned an empty response")
  }
  raise fail("'\{name}' did not return a response to request \{id}")
}

///|
/// One HTTP exchange, following same-origin redirects with the method rules
/// used by MCP clients: 301/302 preserve non-POST methods and turn POST into
/// GET, 303 turns everything except HEAD into GET, and 307/308 preserve both
/// method and body. Session-termination DELETEs therefore survive 301/302.
async fn http_exchange(
  link : HttpLink,
  request_method : @http.RequestMethod,
  url : String,
  body : String,
  name : String,
  timeout_ms : Int32,
) -> (Int32, String) raise Error {
  let mut current_method = request_method
  let mut current_url = url
  let mut current_body = body
  let mut redirects = 0
  while true {
    let (response, text) = http_send_once(
      link, current_method, current_url, current_body, name, timeout_ms,
    )
    if !is_redirect(response.code) {
      return (response.code, text)
    }
    let location = match
      response.headers.get(@http.CaseInsensitiveString("location")) {
      Some(location) if location.trim().length() > 0 =>
        location.trim().to_owned()
      _ => return (response.code, text)
    }
    if redirects >= 10 {
      raise fail("'\{name}' exceeded 10 HTTP redirects")
    }
    let next_url = resolve_redirect_url(current_url, location)
    if url_origin(current_url) != url_origin(next_url) {
      raise fail(
        "'\{name}' redirected to another origin (\{next_url}); mcpbox only follows same-origin redirects",
      )
    }
    let next_method = redirect_method(current_method, response.code)
    if next_method != current_method {
      current_body = ""
    }
    current_method = next_method
    current_url = next_url
    redirects += 1
  }
  (0, "")
}

///|
fn is_redirect(code : Int32) -> Bool {
  code == 301 || code == 302 || code == 303 || code == 307 || code == 308
}

///|
/// The method used for the next hop. A changed method drops the body, as
/// required for a redirected POST that becomes a GET.
fn redirect_method(
  request_method : @http.RequestMethod,
  code : Int32,
) -> @http.RequestMethod {
  match code {
    301 | 302 =>
      match request_method {
        @http.Post => @http.Get
        _ => request_method
      }
    303 =>
      match request_method {
        @http.Head => @http.Head
        _ => @http.Get
      }
    _ => request_method
  }
}

///|
/// Send one HTTP request and return the response and body text. Redirect
/// responses are returned to the caller so it can decide whether to follow
/// them.
async fn http_send_once(
  link : HttpLink,
  request_method : @http.RequestMethod,
  url : String,
  body : String,
  name : String,
  timeout_ms : Int32,
) -> (@http.Response, String) raise Error {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[@http.CaseInsensitiveString("accept")] = "application/json, text/event-stream"
  // The MoonBit HTTP client only decompresses `gzip`, which it advertises
  // itself. Ignore a caller-supplied Accept-Encoding so a server cannot pick a
  // coding the client would hand back as opaque bytes.
  let is_body_request = match request_method {
    @http.Get | @http.Head => false
    _ => true
  }
  // Encode the body once, as UTF-8 bytes. `String::length()` counts UTF-16
  // code units, so it is wrong for non-ASCII tool arguments (a Chinese payload
  // is 3 bytes each, emoji 4); `Content-Length` must be the byte count or the
  // HTTP client rejects the length mismatch with `IncorrectBodyLength`.
  let payload : Bytes = if is_body_request { @utf8.encode(body) } else { [] }
  let has_payload = payload.length() > 0
  if has_payload {
    headers[@http.CaseInsensitiveString("content-type")] = "application/json"
    headers[@http.CaseInsensitiveString("content-length")] = payload
      .length()
      .to_string()
  }
  for entry in link.headers {
    let key = entry.0
    let lower = key.to_lower()
    if lower == "accept-encoding" ||
      lower == "content-length" ||
      lower == "content-type" {
      continue
    }
    headers[@http.CaseInsensitiveString(key)] = entry.1
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
  let (origin, path) = split_url(url)
  let (response, data) = @async.with_timeout(
    timeout_ms,
    () => {
      let client = @http.Client::Client(origin)
      defer client.close()
      let response = if has_payload {
        client
        ..request(request_method, path, extra_headers=headers)
        ..write(payload)
        .end_request()
      } else {
        client
        ..request(request_method, path, extra_headers=headers)
        .end_request()
      }
      (response, client.read_all())
    },
    error=fail("timed out after \{timeout_ms}ms calling '\{name}'"),
  ) catch {
    e => raise fail("cannot reach '\{name}': \{error_text(e)}")
  }
  match response.headers.get(@http.CaseInsensitiveString("mcp-session-id")) {
    Some(session_id) => link.session_id = Some(session_id)
    None => ()
  }
  let text = data.text() catch {
    e => raise fail("cannot read the response from '\{name}': \{error_text(e)}")
  }
  (response, text)
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
  let chars = url.to_array()
  let mut split = -1
  let mut i = scheme_end
  while i < chars.length() {
    if chars[i] == '/' || chars[i] == '?' || chars[i] == '#' {
      split = i
      break
    }
    i += 1
  }
  if split < 0 {
    return (url + "/", "/")
  }
  let mut end = chars.length()
  i = split
  while i < chars.length() {
    if chars[i] == '#' {
      end = i
      break
    }
    i += 1
  }
  let origin = url.exact_view(end=split).to_owned() + "/"
  let path = if chars[split] == '/' {
    url.exact_view(start=split, end~).to_owned()
  } else {
    "/" + url.exact_view(start=split, end~).to_owned()
  }
  (origin, path)
}

///|
/// The scheme and authority of a URL (`https://host:port`), used to keep
/// redirects on the same origin so session ids and configured headers never
/// leak to a different host.
fn url_origin(url : String) -> String {
  let scheme_end = match url.find("://") {
    Some(index) => index + 3
    None => 0
  }
  let chars = url.to_array()
  let mut end = chars.length()
  let mut i = scheme_end
  while i < chars.length() {
    if chars[i] == '/' || chars[i] == '?' || chars[i] == '#' {
      end = i
      break
    }
    i += 1
  }
  let scheme = url.exact_view(end=scheme_end).to_owned()
  let authority = url.exact_view(start=scheme_end, end~).to_owned()
  let scheme = scheme.to_lower()
  let authority = authority.to_lower()
  // Fold the default port away so a redirect that makes `:443` explicit (or
  // drops it) still counts as the same origin.
  if scheme.has_prefix("http:") && authority.has_suffix(":80") {
    "http://" + authority[:authority.length() - 3].to_owned()
  } else if scheme.has_prefix("https:") && authority.has_suffix(":443") {
    "https://" + authority[:authority.length() - 4].to_owned()
  } else {
    scheme + authority
  }
}

///|
/// The path part of a URL, without query or fragment.
fn url_path(url : String) -> String {
  let scheme_end = match url.find("://") {
    Some(index) => index + 3
    None => 0
  }
  let chars = url.to_array()
  let mut start = -1
  let mut i = scheme_end
  while i < chars.length() {
    if chars[i] == '/' || chars[i] == '?' || chars[i] == '#' {
      start = i
      break
    }
    i += 1
  }
  if start < 0 {
    return "/"
  }
  if chars[start] != '/' {
    return "/"
  }
  let mut end = chars.length()
  i = start
  while i < chars.length() {
    if chars[i] == '?' || chars[i] == '#' {
      end = i
      break
    }
    i += 1
  }
  url.exact_view(start~, end~).to_owned()
}

///|
/// Drop a query string and fragment from a URL.
fn url_without_query(url : String) -> String {
  let chars = url.to_array()
  let mut end = chars.length()
  let mut i = 0
  while i < chars.length() {
    if chars[i] == '?' || chars[i] == '#' {
      end = i
      break
    }
    i += 1
  }
  url.exact_view(end~).to_owned()
}

///|
/// Resolve a `Location` header against the URL that produced it. Handles
/// absolute URLs, scheme-relative URLs, root-relative paths, query-only
/// references and relative paths.
fn resolve_redirect_url(base : String, location : String) -> String {
  let loc = location.trim().to_owned()
  if loc.has_prefix("http://") || loc.has_prefix("https://") {
    return loc
  }
  let origin = url_origin(base)
  if loc.has_prefix("//") {
    let scheme_end = match base.find("://") {
      Some(index) => index
      None => 0
    }
    return base.exact_view(end=scheme_end).to_owned() + ":" + loc
  }
  if loc.has_prefix("/") {
    return origin + loc
  }
  if loc.has_prefix("?") {
    return url_without_query(base) + loc
  }
  if loc.has_prefix("#") {
    return url_without_query(base) + loc
  }
  let path = url_path(base)
  let dir = match path.rev_find("/") {
    Some(index) => path.exact_view(end=index + 1).to_owned()
    None => "/"
  }
  // Normalise dot segments (`../next`) against the base path; origin only.
  let joined = @path.Path(dir + loc).normalize().to_string()
  origin + joined
}

///|
/// Split an HTTP body into the JSON payloads carried by its SSE events. A
/// plain JSON body is returned as a single payload. Data lines belonging to
/// one event are joined with a newline, and a blank line closes the event.
fn sse_events(body : String) -> Array[String] {
  let trimmed_body = body.trim().to_owned()
  if trimmed_body.has_prefix("{") ||
    trimmed_body.has_prefix("[") ||
    !trimmed_body.contains("data:") {
    return [trimmed_body]
  }
  let events : Array[String] = []
  let current = StringBuilder()
  let mut has_data = false
  for raw in body.split("\n") {
    let line = raw.trim()
    if line.length() == 0 {
      if has_data {
        events.push(current.to_string())
        current.reset()
        has_data = false
      }
      continue
    }
    if line.has_prefix("data:") {
      if has_data {
        current.write_string("\n")
      }
      current.write_string(line[5:].trim().to_owned())
      has_data = true
    }
  }
  if has_data {
    events.push(current.to_string())
  }
  events
}

///|
/// Find the response with a matching id inside a single object or a batch.
fn find_response(
  json : Json,
  id : Int32,
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

///|
/// Open the legacy HTTP+SSE stream: a GET that must answer with an event
/// stream. The caller then waits for the `endpoint` event.
async fn sse_open(
  url : String,
  headers : Map[String, String],
  last_event_id : String,
  name : String,
  timeout_ms : Int32,
) -> @http.Client raise Error {
  let (origin, path) = split_url(url)
  let client = @http.Client::Client(origin)
  let request_headers : Map[@http.CaseInsensitiveString, String] = Map([])
  request_headers[@http.CaseInsensitiveString("accept")] = "text/event-stream"
  for entry in headers {
    let lower = entry.0.to_lower()
    if lower == "accept" ||
      lower == "accept-encoding" ||
      lower == "content-length" ||
      lower == "content-type" {
      continue
    }
    request_headers[@http.CaseInsensitiveString(entry.0)] = entry.1
  }
  if last_event_id.length() > 0 {
    request_headers[@http.CaseInsensitiveString("last-event-id")] = last_event_id
  }
  let response = @async.with_timeout(
    timeout_ms,
    () => {
      client
      ..request(@http.Get, path, extra_headers=request_headers)
      .end_request()
    },
    error=fail(
      "timed out after \{timeout_ms}ms opening the event stream from '\{name}'",
    ),
  ) catch {
    e => {
      client.close()
      raise fail(
        "cannot open the event stream from '\{name}': \{error_text(e)}",
      )
    }
  }
  if response.code != 200 {
    client.close()
    raise fail(
      "'\{name}' returned HTTP \{response.code} for the SSE stream instead of 200 text/event-stream",
    )
  }
  match response.headers.get(@http.CaseInsensitiveString("content-type")) {
    Some(content_type) if !content_type.to_lower().contains("text/event-stream") => {
      client.close()
      raise fail(
        "'\{name}' returned '\{content_type}' instead of text/event-stream; check whether the URL is a Streamable HTTP endpoint",
      )
    }
    _ => ()
  }
  client
}

///|
/// Wait for the `endpoint` event that names where to POST messages. Servers
/// repeat it on every new stream, so reconnecting refreshes the endpoint.
async fn sse_await_endpoint(
  link : SseLink,
  name : String,
  timeout_ms : Int32,
) -> Unit raise Error {
  while true {
    match read_sse_event(link, name, timeout_ms) {
      None =>
        raise fail(
          "'\{name}' closed the event stream before sending an endpoint",
        )
      Some((event_type, data)) =>
        if event_type == "endpoint" {
          if data.length() == 0 {
            raise fail("'\{name}' sent an empty SSE endpoint event")
          }
          link.endpoint = resolve_sse_endpoint(link.url, data, name)
          return
        }
    }
  }
}

///|
async fn sse_connect(
  url : String,
  headers : Map[String, String],
  name : String,
  timeout_ms : Int32,
) -> SseLink raise Error {
  let client = sse_open(url, headers, "", name, timeout_ms)
  let link : SseLink = {
    url,
    headers,
    client,
    endpoint: "",
    last_event_id: "",
  }
  let opened : Result[Unit, Error] = try {
    sse_await_endpoint(link, name, timeout_ms)
    Ok(())
  } catch {
    error => Err(error)
  }
  match opened {
    Ok(_) => link
    Err(error) => {
      link.client.close()
      raise error
    }
  }
}

///|
/// Drop the dead stream, reopen it with `Last-Event-ID`, and refresh the
/// endpoint. The pending request is not re-sent, so a server that never saw it
/// cannot act on it twice.
async fn sse_reconnect(
  link : SseLink,
  name : String,
  timeout_ms : Int32,
) -> Unit raise Error {
  link.client.close()
  link.client = sse_open(
    link.url,
    link.headers,
    link.last_event_id,
    name,
    timeout_ms,
  )
  sse_await_endpoint(link, name, timeout_ms)
}

///|
/// Read one complete server-sent event, skipping comments and `retry:` hints.
/// Returns the event name (`message` when the stream omits it) and its joined
/// data lines, or `None` once the stream closes. Event `id:`s are remembered so
/// a reconnect can send `Last-Event-ID`.
async fn read_sse_event(
  link : SseLink,
  name : String,
  timeout_ms : Int32,
) -> (String, String)? raise Error {
  let mut event_type = ""
  let mut event_id : String? = None
  let data = StringBuilder()
  let mut has_data = false
  while true {
    let line = @async.with_timeout(
      timeout_ms,
      () => link.client.read_until("\n"),
      error=fail("timed out after \{timeout_ms}ms waiting for '\{name}'"),
    ) catch {
      e => raise fail("cannot read from '\{name}': \{error_text(e)}")
    }
    let raw = match line {
      None => return None
      Some(text) => text
    }
    let text = raw.trim().to_owned()
    if text.length() == 0 {
      if has_data {
        match event_id {
          Some(id) => if id.length() > 0 { link.last_event_id = id }
          None => ()
        }
        let resolved_type = if event_type.length() == 0 {
          "message"
        } else {
          event_type
        }
        return Some((resolved_type, data.to_string()))
      }
      continue
    }
    if text.has_prefix(":") {
      continue
    }
    if text.has_prefix("event:") {
      event_type = text[6:].trim().to_owned()
    } else if text.has_prefix("data:") {
      if has_data {
        data.write_string("\n")
      }
      data.write_string(text[5:].trim().to_owned())
      has_data = true
    } else if text.has_prefix("id:") {
      let id = text[3:].trim().to_owned()
      if id.length() > 0 {
        event_id = Some(id)
      }
    }
  }
  None
}

///|
/// Resolve the `endpoint` event against the stream URL and keep it on the same
/// origin, so configured headers are never forwarded to a third-party host.
fn resolve_sse_endpoint(
  base : String,
  data : String,
  name : String,
) -> String raise McpError {
  let endpoint = resolve_redirect_url(base, data)
  if url_origin(endpoint) != url_origin(base) {
    raise fail(
      "'\{name}' sent an SSE endpoint on another origin (\{endpoint}); refusing to forward messages there",
    )
  }
  endpoint
}

///|
/// POST one JSON-RPC message to the endpoint named by the SSE stream.
async fn sse_post(
  link : SseLink,
  message : Json,
  name : String,
  timeout_ms : Int32,
) -> Unit raise Error {
  let post : HttpLink = {
    url: link.endpoint,
    headers: link.headers,
    session_id: None,
  }
  let (code, body) = http_exchange(
    post,
    @http.Post,
    link.endpoint,
    message.stringify(),
    name,
    timeout_ms,
  )
  if code >= 300 {
    raise fail("'\{name}' rejected a message with HTTP \{code}: \{body}")
  }
}

///|
/// Send a request over the SSE transport: POST it, then read the event stream
/// until its response arrives.
async fn sse_request(
  link : SseLink,
  message : Json,
  id : Int32,
  name : String,
  timeout_ms : Int32,
) -> Json raise Error {
  sse_post(link, message, name, timeout_ms)
  sse_await_response(link, id, name, timeout_ms)
}

///|
/// Read events until the response to `id` arrives, answering server requests
/// and skipping notifications. A late `endpoint` event updates the POST URL.
/// When the stream closes, reconnect (bounded) and keep waiting for the same
/// response; the request is not re-sent.
async fn sse_await_response(
  link : SseLink,
  id : Int32,
  name : String,
  timeout_ms : Int32,
) -> Json raise Error {
  let mut reconnects : Int32 = 0
  while true {
    match read_sse_event(link, name, timeout_ms) {
      None => {
        if reconnects >= SSE_MAX_RECONNECTS {
          raise fail(
            "'\{name}' closed the event stream and \{SSE_MAX_RECONNECTS} reconnects did not restore it",
          )
        }
        reconnects += 1
        @async.sleep(200 * reconnects)
        sse_reconnect(link, name, timeout_ms)
      }
      Some((event_type, data)) => {
        if event_type == "endpoint" {
          if data.length() == 0 {
            raise fail("'\{name}' sent an empty SSE endpoint event")
          }
          link.endpoint = resolve_sse_endpoint(link.url, data, name)
          continue
        }
        if data.length() == 0 {
          continue
        }
        let json = @json.parse(data) catch {
          e => raise fail("'\{name}' sent invalid JSON: \{e.to_string()}")
        }
        answer_sse_server_requests(link, json, name, timeout_ms)
        match find_response(json, id) {
          Some(Ok(result)) => return result
          Some(Err(error)) => raise fail("\{name}: \{error.message}")
          None => ()
        }
      }
    }
  }
  Json::null()
}

///|
/// Answer server-initiated requests carried by an SSE event. Batches are
/// walked element by element.
async fn answer_sse_server_requests(
  link : SseLink,
  json : Json,
  name : String,
  timeout_ms : Int32,
) -> Unit raise Error {
  match json {
    Array(items) =>
      for item in items {
        answer_sse_server_request(link, item, name, timeout_ms)
      }
    _ => answer_sse_server_request(link, json, name, timeout_ms)
  }
}

///|
async fn answer_sse_server_request(
  link : SseLink,
  json : Json,
  name : String,
  timeout_ms : Int32,
) -> Unit raise Error {
  match decode_rpc_message(json) {
    Some(ServerRequest(server_id, method_name, _)) =>
      sse_post(
        link,
        rpc_error_response(
          server_id,
          -32601,
          "mcpbox does not implement '\{method_name}'",
        ),
        name,
        timeout_ms,
      )
    _ => ()
  }
}
