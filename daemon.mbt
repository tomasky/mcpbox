///|
/// Optional, per-user keep-alive service. IPC is authenticated newline JSON on
/// loopback TCP; the address and random secret live in a private directory.
/// Requests are handled serially so two clients never read one MCP stream.
priv struct DaemonLocator {
  port : Int32
  token : String
}

///|
priv struct DaemonEntry {
  name : String
  fingerprint : String
  live : LiveSession
}

///|
async fn startup_progress(opts : Options, message : String) -> Unit {
  if !opts.quiet && !opts.json {
    @stdio.stderr.write("mcpbox: " + message + "\n") catch {
      _ => ()
    }
  }
}

///|
/// Animate only when stderr is a terminal. Pipes, CI logs, `--quiet` and
/// `--json` keep their existing plain (or silent) output.
fn interactive_progress(opts : Options) -> Bool {
  !opts.quiet && !opts.json && mcpbox_is_tty(2)
}

///|
/// Individual "connecting to..." lines would fight the spinner's carriage
/// returns, so on a terminal the spinner is the only thing drawn while
/// servers start.
async fn server_progress(opts : Options, message : String) -> Unit {
  if !interactive_progress(opts) {
    startup_progress(opts, message)
  }
}

///|
fn progress_line(label : String, frame : Int32, elapsed_ms : Int32) -> String {
  let frames : Array[String] = [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
  ]
  "\r\u{001b}[2Kmcpbox: " +
  label +
  " " +
  frames[frame % frames.length()] +
  " " +
  (elapsed_ms / 1000).to_string() +
  "s"
}

///|
/// Redraw one status line until the task group cancels it. The initial delay
/// avoids a distracting flash when every server answers quickly.
async fn spinner_loop(label : String) -> Unit {
  @async.sleep(300)
  let mut frame = 0
  let mut elapsed_ms = 300
  while true {
    @stdio.stderr.write(progress_line(label, frame, elapsed_ms)) catch {
      _ => ()
    }
    @async.sleep(100)
    frame += 1
    elapsed_ms += 100
  }
}

///|
async fn clear_progress_line() -> Unit {
  @stdio.stderr.write("\r\u{001b}[2K") catch {
    _ => ()
  }
}

///|
fn daemon_directory() -> String raise McpError {
  match @env.get_env_var("XDG_RUNTIME_DIR") {
    Some(path) if path.length() > 0 => path + "/mcpbox"
    _ => {
      let home = home_dir()
      if home.length() == 0 {
        raise fail("background mode needs HOME or XDG_RUNTIME_DIR")
      }
      home + "/.cache/mcpbox/run"
    }
  }
}

///|
fn native_path(path : String) -> Bytes {
  @utf8.encode(path + "\u{0000}")
}

///|
fn daemon_string(value : Json, field : String) -> String raise McpError {
  match value {
    Object(fields) =>
      match fields.get(field) {
        Some(String(text)) => text
        _ => raise fail("daemon message needs a string '\{field}'")
      }
    _ => raise fail("daemon message must be an object")
  }
}

///|
fn daemon_field(value : Json, field : String) -> Json raise McpError {
  match value {
    Object(fields) =>
      match fields.get(field) {
        Some(result) => result
        None => raise fail("daemon message is missing '\{field}'")
      }
    _ => raise fail("daemon message must be an object")
  }
}

///|
fn daemon_port(value : Json) -> Int32 raise McpError {
  let text = daemon_string(value, "port")
  let port = @string.parse_int(text) catch {
    _ => raise fail("invalid daemon port")
  }
  if port <= 0 || port > 65535 {
    raise fail("invalid daemon port")
  }
  port
}

///|
async fn read_daemon_locator() -> DaemonLocator? {
  try {
    let directory = daemon_directory()
    if !mcpbox_private_directory(native_path(directory)) {
      return None
    }
    let value = @json.parse(@fs.read_file(directory + "/endpoint.json").text())
    Some({ port: daemon_port(value), token: daemon_string(value, "token"), })
  } catch {
    _ => None
  }
}

///|
/// A connect-only probe also works while the service is busy with a tool.
/// Never interpret a slow tool as a reason to launch a second service.
async fn running_daemon() -> DaemonLocator? {
  match read_daemon_locator() {
    None => None
    Some(locator) => {
      let reachable = @async.with_timeout_opt(500, () => {
        let conn = @socket.Tcp::connect(
          @socket.Addr::parse("127.0.0.1:\{locator.port}"),
        )
        conn.close()
        true
      }) catch {
        _ => None
      }
      if reachable is Some(true) {
        Some(locator)
      } else {
        None
      }
    }
  }
}

///|
/// `-b` starts the service when necessary. Ordinary commands reuse an existing
/// service, but remain one-shot if none is running. Calls are never retried:
/// a lost reply might mean a side-effecting tool already ran.
async fn daemon_for_command(opts : Options) -> DaemonLocator? raise Error {
  let existing = running_daemon()
  if existing is Some(_) || !opts.background {
    return existing
  }
  let directory = daemon_directory()
  @fs.mkdir(directory, recursive=true, allow_exist=true, permission=0o700)
  if !mcpbox_private_directory(native_path(directory)) {
    raise fail(
      "daemon directory must be owned by you and private (0700): " + directory,
    )
  }
  startup_progress(opts, "starting background service…")
  let argv = @env.args()
  if argv.length() == 0 {
    raise fail("cannot find the mcpbox executable")
  }
  let executable = @fs.realpath(argv[0]) catch { _ => argv[0] }
  let input = @process.redirect_from_file("/dev/null")
  let output = @process.redirect_to_file(
    directory + "/daemon.log",
    append=true,
    permission=0o600,
  )
  ignore(
    @process.spawn_orphan(
      executable,
      ["__daemon"],
      stdin=input,
      stdout=output,
      stderr=output,
    ),
  )
  // Racing launchers are harmless: only the process holding the OS lock may
  // publish an endpoint. No stale PID or lock-directory recovery is needed.
  for _ in 0..<100 {
    match running_daemon() {
      Some(locator) => return Some(locator)
      None => @async.sleep(50)
    }
  }
  raise fail(
    "background service did not start; see " + directory + "/daemon.log",
  )
}

///|
/// Stable serialization is used only for detecting changed server settings;
/// object insertion order must not cause unnecessary server restarts.
fn daemon_canonical(value : Json) -> String {
  match value {
    Object(fields) => {
      let keys = Array::from_iter(fields.keys())
      keys.sort_by((a, b) => a.lexical_compare(b))
      let parts : Array[String] = []
      for key in keys {
        parts.push(
          Json::string(key).stringify() +
          ":" +
          daemon_canonical(fields.get(key).unwrap_or(Json::null())),
        )
      }
      "{" + parts.join(",") + "}"
    }
    Array(values) => "[" + values.map(daemon_canonical).join(",") + "]"
    _ => value.stringify()
  }
}

///|
fn daemon_map_json(values : Map[String, String]) -> Json {
  let fields : Map[String, Json] = Map([])
  for key, value in values {
    fields[key] = Json::string(value)
  }
  Json::object(fields)
}

///|
fn daemon_string_map(value : Json) -> Map[String, String] raise McpError {
  guard value is Object(fields) else {
    raise fail("expected daemon string map")
  }
  let result : Map[String, String] = Map([])
  for key, value in fields {
    guard value is String(text) else {
      raise fail("expected daemon string value")
    }
    result[key] = text
  }
  result
}

///|
/// Pass resolved configuration, not a name to rediscover in the daemon's cwd.
/// A stdio child's complete environment comes from this client, not from the
/// shell that happened to launch the service first.
fn daemon_work(operation : String, server : Server, opts : Options) -> Json {
  let cwd = @env.current_dir().unwrap_or("")
  let spec = match server.kind {
    Stdio(spec) => {
      let environment = @env.get_env_vars()
      for key, value in spec.env {
        environment[key] = value
      }
      Json::object({
        "command": Json::string(spec.command),
        "args": Json::array(spec.args.map(arg => Json::string(arg))),
        "env": daemon_map_json(environment),
        "cwd": Json::string(if spec.cwd.length() > 0 { spec.cwd } else { cwd }),
      })
    }
    Http(spec) =>
      Json::object({
        "url": Json::string(spec.url),
        "headers": daemon_map_json(spec.headers),
      })
  }
  Json::object({
    "op": Json::string(operation),
    "name": Json::string(server.name),
    "scope": Json::string(
      cwd + "\n" + @env.get_env_var("MCPBOX_CONFIG").unwrap_or(""),
    ),
    "transport": Json::string(transport_label(server)),
    "spec": spec,
    "timeout": Json::string(opts.timeout_ms.to_string()),
  })
}

///|
fn daemon_decode_server(request : Json) -> Server raise McpError {
  let spec = daemon_field(request, "spec")
  let kind = match daemon_string(request, "transport") {
    "stdio" => {
      let args = daemon_strings(daemon_field(spec, "args"))
      ServerKind::Stdio({
        command: daemon_string(spec, "command"),
        args,
        env: daemon_string_map(daemon_field(spec, "env")),
        cwd: daemon_string(spec, "cwd"),
      })
    }
    "http" =>
      ServerKind::Http({
        url: daemon_string(spec, "url"),
        headers: daemon_string_map(daemon_field(spec, "headers")),
      })
    _ => raise fail("unknown daemon transport")
  }
  { name: daemon_string(request, "name"), kind, note: "background session", }
}

///|
fn daemon_strings(value : Json) -> Array[String] raise McpError {
  guard value is Array(values) else {
    raise fail("expected daemon string array")
  }
  let result : Array[String] = []
  for value in values {
    guard value is String(text) else {
      raise fail("expected daemon string argument")
    }
    result.push(text)
  }
  result
}

///|
async fn daemon_request(
  locator : DaemonLocator,
  request : Json,
  timeout_ms : Int32,
) -> Json raise Error {
  guard request is Object(fields) else { raise fail("invalid daemon request") }
  fields["token"] = Json::string(locator.token)
  // A fresh session needs initialization, tools/list, and possibly tools/call.
  // Leave a bounded allowance for those requests and queueing; avoid overflow.
  let budget = if timeout_ms > 500000000 {
    2147483647
  } else {
    timeout_ms * 4 + 10000
  }
  @async.with_timeout(budget, () => {
    let conn = @socket.Tcp::connect(
      @socket.Addr::parse("127.0.0.1:\{locator.port}"),
    )
    defer conn.close()
    conn.write(request.stringify() + "\n")
    let reader : &@io.Reader = conn
    let line = reader.read_until("\n")
    guard line is Some(text) else {
      raise fail("background service disconnected; the request was not retried")
    }
    let response = @json.parse(text)
    match response {
      Object(reply) =>
        match reply.get("error") {
          Some(String(message)) => raise fail(message)
          _ => daemon_field(response, "result")
        }
      _ => raise fail("invalid background service response")
    }
  })
}

///|
async fn daemon_execute(
  request : Json,
  sessions : Map[String, DaemonEntry],
) -> (Json, Bool) raise Error {
  let operation = daemon_string(request, "op")
  if operation == "stop" {
    let name = daemon_string(request, "name")
    let keys = Array::from_iter(sessions.keys())
    let mut stopped = 0
    for key in keys {
      match sessions.get(key) {
        Some(entry) if name == "all" || entry.name == name => {
          sessions.remove(key)
          entry.live.close()
          stopped += 1
        }
        _ => ()
      }
    }
    return (
      Json::object({
        "stopped": Json::number(stopped.to_double(), repr=stopped.to_string()),
      }),
      name == "all",
    )
  }
  if operation != "list" && operation != "call" {
    raise fail("unknown daemon operation")
  }
  let timeout = @string.parse_int(daemon_string(request, "timeout"))
  if timeout <= 0 {
    raise fail("invalid daemon request timeout")
  }
  let server = daemon_decode_server(request)
  let key = daemon_string(request, "scope") + "\n" + server.name
  let fingerprint = daemon_string(request, "transport") +
    daemon_canonical(daemon_field(request, "spec"))
  match sessions.get(key) {
    Some(entry) if entry.fingerprint != fingerprint => {
      sessions.remove(key)
      entry.live.close()
    }
    _ => ()
  }
  let live = match sessions.get(key) {
    Some(entry) => entry.live
    None => {
      let live = open_live_session(server, timeout, inherit_env=false)
      sessions[key] = { name: server.name, fingerprint, live, }
      live
    }
  }
  let outcome : Result[(Json, Bool), Error] = try {
    let session = live.session()
    let tools = session.list_tools(timeout)
    if operation == "list" {
      // parse_server_info expects the MCP initialize shape.
      let info = session.server_info()
      let response = Json::object({
        "serverInfo": Json::object({
          "name": Json::string(info.name),
          "version": Json::string(info.version),
        }),
        "protocolVersion": Json::string(info.protocol_version),
        "instructions": Json::string(info.instructions),
        "tools": Json::array(tools.map(tool_to_json)),
      })
      Ok((response, false))
    } else {
      let name = daemon_string(request, "tool")
      let tool = match find_tool(tools, name) {
        Some(tool) => tool
        None =>
          raise fail(
            "'\{server.name}' has no tool named '\{name}'" +
            available_tools(tools),
          )
      }
      let pairs = daemon_strings(daemon_field(request, "pairs"))
      let arguments = build_arguments(pairs, tool.input_schema)
      Ok(
        (
          call_result_to_json(session.call_tool(name, arguments, timeout)),
          false,
        ),
      )
    }
  } catch {
    error => Err(error)
  }
  match outcome {
    Ok(result) => result
    Err(error) => {
      // After a timeout or malformed reply the MCP stream may be out of sync.
      // Drop it, but never retry the operation automatically.
      sessions.remove(key)
      live.close()
      raise error
    }
  }
}

///|
async fn daemon_main() -> Unit raise Error {
  let directory = daemon_directory()
  if !mcpbox_private_directory(native_path(directory)) {
    raise fail("unsafe daemon directory: " + directory)
  }
  let lock = mcpbox_daemon_lock(native_path(directory + "/service.lock"))
  if lock == -1 {
    return
  }
  if lock < 0 {
    raise fail("cannot lock daemon directory: " + directory)
  }
  defer mcpbox_close_fd(lock)
  let entropy = @env.rand(32)
  guard entropy is Some(bytes) else {
    raise fail("cannot generate daemon authentication token")
  }
  let secret = StringBuilder()
  for i in 0..<bytes.length() {
    secret.write_string(bytes[i].to_int().to_string() + "-")
  }
  let token = secret.to_string()
  let listener = @socket.TcpServer::TcpServer(
    @socket.Addr::parse("127.0.0.1:0"),
  )
  defer listener.close()
  let endpoint = directory + "/endpoint.json"
  let locator = Json::object({
    "port": Json::string(listener.addr.port().to_string()),
    "token": Json::string(token),
  })
  @fs.write_file(
    endpoint + ".tmp",
    locator.stringify(),
    create_mode=@fs.CreateOrTruncate,
    permission=0o600,
  )
  @fs.rename(endpoint + ".tmp", endpoint, replace=true)
  let sessions : Map[String, DaemonEntry] = Map([])
  let outcome : Result[Unit, Error] = try {
    let mut stopping = false
    while !stopping {
      let (conn, _) = listener.accept()
      defer conn.close()
      try {
        let reader : &@io.Reader = conn
        let line = @async.with_timeout(5000, () => reader.read_until("\n"))
        match line {
          None => () // A connect-only liveness probe.
          Some(text) => {
            let request = @json.parse(text)
            if daemon_string(request, "token") != token {
              raise fail("invalid background service token")
            }
            let response = try {
              let (result, quit) = daemon_execute(request, sessions)
              stopping = quit
              Json::object({ "result": result })
            } catch {
              error =>
                Json::object({ "error": Json::string(error_text(error)) })
            }
            @async.with_timeout(5000, () => {
              conn.write(response.stringify() + "\n")
            })
          }
        }
      } catch {
        _ => ()
      } // A disconnected client must not stop other sessions.
    }
    Ok(())
  } catch {
    error => Err(error)
  }
  for _, entry in sessions {
    entry.live.close()
  }
  @fs.remove(endpoint) catch {
    _ => ()
  }
  match outcome {
    Ok(_) => ()
    Err(error) => raise error
  }
}

///|
async fn cmd_stop(args : Array[String]) -> Unit raise Error {
  let opts = parse_options(args)
  if opts.help {
    print_line(help_text())
    return
  }
  if opts.positional.length() != 1 {
    raise fail("usage: mcpbox stop <server|all>")
  }
  let name = opts.positional[0]
  let result = match running_daemon() {
    None => Json::object({ "stopped": Json::number(0.0, repr="0") })
    Some(locator) =>
      daemon_request(
        locator,
        Json::object({ "op": Json::string("stop"), "name": Json::string(name) }),
        opts.timeout_ms,
      )
  }
  if opts.json {
    print_line(result.stringify())
  } else {
    print_line(
      "\{name}: " +
      daemon_field(result, "stopped").stringify() +
      " background session(s) stopped",
    )
  }
}
