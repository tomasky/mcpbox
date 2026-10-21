///|
/// The mcpbox command line: argument parsing, command dispatch, and the
/// human/JSON rendering of results.

///|
/// Options shared by the commands.
priv struct Options {
  mut json : Bool
  mut brief : Bool
  mut raw : Bool
  mut help : Bool
  mut timeout_ms : Int32
  mut http_url : String?
  mut stdio : String?
  positional : Array[String]
}

///|
/// A server plus the outcome of talking to it. `list` reports one of these per
/// server, whether the connection worked or not.
priv struct ServerReport {
  server : Server
  mut info : ServerInfo?
  mut tools : Array[Tool]
  mut error : String?
}

///|
/// Write one line to standard output. A closed pipe (`mcpbox list | head`) is
/// not an error worth reporting.
async fn print_line(text : String) -> Unit {
  @stdio.stdout.write(text + "\n") catch {
    _ => ()
  }
}

///|
/// The argument list without the program name.
fn tail(args : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for i in 1..<args.length() {
    out.push(args[i])
  }
  out
}

///|
/// Parse a number of seconds into milliseconds. The timeout must be a finite
/// positive duration that fits in an `Int`; `Infinity` and `NaN` are rejected
/// rather than silently becoming a zero or negative deadline.
fn parse_seconds(text : String) -> Int32 raise McpError {
  let seconds = @string.parse_double(text.trim()) catch {
    _ => raise fail("'\{text}' is not a number of seconds")
  }
  if seconds.is_nan() || seconds.is_inf() || seconds <= 0.0 {
    raise fail("the timeout must be a positive, finite number of seconds")
  }
  let millis = seconds * 1000.0
  if millis < 1.0 {
    raise fail("the timeout must be at least 0.001 seconds")
  }
  if millis > 2147483647.0 {
    raise fail("the timeout is too large")
  }
  millis.to_int()
}

///|
/// Split a command string the way a shell would, honouring single and double
/// quotes. Used by `--stdio "npx -y server"`.
fn shell_split(command : String) -> Array[String] {
  let parts : Array[String] = []
  let current = StringBuilder()
  let chars = command.to_array()
  let mut i = 0
  let mut in_quote = false
  let mut quote_char : Char = '"'
  let mut has_content = false
  while i < chars.length() {
    let c = chars[i]
    if in_quote {
      if c == quote_char {
        in_quote = false
      } else {
        current.write_char(c)
      }
      has_content = true
    } else if c == '"' || c == '\'' {
      in_quote = true
      quote_char = c
      has_content = true
    } else if c == ' ' || c == '\t' || c == '\n' {
      if has_content {
        parts.push(current.to_string())
        current.reset()
        has_content = false
      }
    } else {
      current.write_char(c)
      has_content = true
    }
    i += 1
  }
  if has_content {
    parts.push(current.to_string())
  }
  parts
}

///|
/// Parse the flags every command understands. Unknown `--flags` are an error
/// rather than being mistaken for tool arguments.
fn parse_options(args : Array[String]) -> Options raise McpError {
  let opts : Options = {
    json: false,
    brief: false,
    raw: false,
    help: false,
    timeout_ms: 30000,
    http_url: None,
    stdio: None,
    positional: [],
  }
  let mut i = 0
  let mut only_positional = false
  while i < args.length() {
    let arg = args[i]
    if only_positional {
      opts.positional.push(arg)
      i += 1
    } else if arg == "--" {
      only_positional = true
      i += 1
    } else if arg == "--json" {
      opts.json = true
      i += 1
    } else if arg == "--brief" {
      opts.brief = true
      i += 1
    } else if arg == "--raw" {
      opts.raw = true
      i += 1
    } else if arg == "--timeout" {
      if i + 1 >= args.length() {
        raise fail("--timeout needs a value in seconds")
      }
      opts.timeout_ms = parse_seconds(args[i + 1])
      i += 2
    } else if arg.has_prefix("--timeout=") {
      opts.timeout_ms = parse_seconds(arg[10:].to_owned())
      i += 1
    } else if arg == "--http-url" {
      if i + 1 >= args.length() {
        raise fail("--http-url needs a URL")
      }
      opts.http_url = Some(args[i + 1])
      i += 2
    } else if arg.has_prefix("--http-url=") {
      opts.http_url = Some(arg[11:].to_owned())
      i += 1
    } else if arg == "--stdio" {
      if i + 1 >= args.length() {
        raise fail("--stdio needs a command")
      }
      opts.stdio = Some(args[i + 1])
      i += 2
    } else if arg.has_prefix("--stdio=") {
      opts.stdio = Some(arg[8:].to_owned())
      i += 1
    } else if arg == "--help" || arg == "-h" {
      opts.help = true
      i += 1
    } else if arg.has_prefix("--") {
      raise fail("unknown option '\{arg}'")
    } else {
      opts.positional.push(arg)
      i += 1
    }
  }
  opts
}

///|
/// The ad-hoc server described by `--http-url` or `--stdio`, if any.
fn adhoc_server(opts : Options) -> Server? raise McpError {
  match opts.http_url {
    Some(url) => {
      let can_connect = url.has_prefix("http://") || url.has_prefix("https://")
      if !can_connect {
        raise fail("'\{url}' should start with http:// or https://")
      }
      return Some({
        name: "adhoc",
        kind: Http({ url, headers: Map([]), }),
        note: "ad-hoc --http-url",
      })
    }
    None => ()
  }
  match opts.stdio {
    Some(command) => {
      let parts = shell_split(command)
      if parts.length() == 0 {
        raise fail("--stdio needs a command")
      }
      let argv : Array[String] = []
      for i in 1..<parts.length() {
        argv.push(parts[i])
      }
      Some({
        name: "adhoc",
        kind: Stdio({ command: parts[0], args: argv, env: Map([]), cwd: "", }),
        note: "ad-hoc --stdio",
      })
    }
    None => None
  }
}

///|
/// The servers a command should talk to: the ad-hoc one if the flags asked for
/// it, otherwise everything discovered from config.
async fn resolve_servers(opts : Options) -> Array[Server] raise Error {
  match adhoc_server(opts) {
    Some(server) => [server]
    None => load_servers()
  }
}

///|
/// Find a server by name.
fn find_server(servers : Array[Server], name : String) -> Server? {
  for server in servers {
    if server.name == name {
      return Some(server)
    }
  }
  None
}

///|
/// A `, `-separated list of server names for an error message.
fn available_names(servers : Array[Server]) -> String {
  if servers.length() == 0 {
    return " (no servers are configured)"
  }
  let names : Array[String] = []
  for server in servers {
    names.push(server.name)
  }
  " (available: " + names.join(", ") + ")"
}

///|
/// A `, `-separated list of tool names for an error message.
fn available_tools(tools : Array[Tool]) -> String {
  if tools.length() == 0 {
    return " (it advertises no tools)"
  }
  let names : Array[String] = []
  for tool in tools {
    names.push(tool.name)
  }
  " (available: " + names.join(", ") + ")"
}

///|
/// Split a `server.tool` target. A bare name is allowed when an ad-hoc server
/// is in play, since there is then only one server to mean.
fn split_target(
  target : String,
  has_adhoc : Bool,
) -> (String, String) raise McpError {
  match target.find(".") {
    Some(index) =>
      if index == 0 || index + 1 >= target.length() {
        raise fail("'" + target + "' must be <server>.<tool>")
      } else {
        (
          target.exact_view(end=index).to_owned(),
          target.exact_view(start=index + 1).to_owned(),
        )
      }
    None =>
      if has_adhoc {
        ("adhoc", target)
      } else {
        raise fail("'" + target + "' must be <server>.<tool>")
      }
  }
}

///|
/// Find a tool by name.
fn find_tool(tools : Array[Tool], name : String) -> Tool? {
  for tool in tools {
    if tool.name == name {
      return Some(tool)
    }
  }
  None
}

///|
/// Connect to a server and collect its tools, converting any failure into a
/// report rather than an exception so one broken server does not hide the rest.
async fn fetch_server(server : Server, timeout_ms : Int32) -> ServerReport {
  let report : ServerReport = { server, info: None, tools: [], error: None, }
  with_server(server, timeout_ms, session => {
    report.info = Some(session.server_info())
    report.tools = session.list_tools(timeout_ms)
  }) catch {
    error => report.error = Some(error_text(error))
  }
  report
}

///|
/// `mcpbox list [server ...]`
async fn cmd_list(args : Array[String]) -> Unit raise Error {
  let opts = parse_options(args)
  if opts.help {
    print_line(help_text())
    return
  }
  let servers = resolve_servers(opts)
  let selected : Array[Server] = []
  if opts.positional.length() == 0 {
    for server in servers {
      selected.push(server)
    }
  } else {
    for name in opts.positional {
      match find_server(servers, name) {
        Some(server) => selected.push(server)
        None =>
          raise fail(
            "no server named '" + name + "'" + available_names(servers),
          )
      }
    }
  }
  if selected.length() == 0 {
    if opts.json {
      print_line(Json::object({ "servers": Json::array([]) }).stringify())
    } else {
      print_line("no MCP servers configured")
    }
    return
  }
  let tasks : Array[async () -> ServerReport] = []
  for server in selected {
    tasks.push(() => fetch_server(server, opts.timeout_ms))
  }
  let reports = @async.all(tasks)
  if opts.json {
    print_line(render_reports_json(reports))
  } else {
    print_line(render_reports_text(reports, opts))
  }
}

///|
/// `mcpbox call <server>.<tool> [key=value ...]`
async fn cmd_call(args : Array[String]) -> Unit raise Error {
  let opts = parse_options(args)
  if opts.help {
    print_line(help_text())
    return
  }
  if opts.positional.length() == 0 {
    raise fail("usage: mcpbox call <server>.<tool> [key=value ...]")
  }
  let servers = resolve_servers(opts)
  let has_adhoc = adhoc_server(opts) is Some(_)
  let (server_name, tool_name) = split_target(opts.positional[0], has_adhoc)
  let server = match find_server(servers, server_name) {
    Some(server) => server
    None =>
      raise fail(
        "no server named '" + server_name + "'" + available_names(servers),
      )
  }
  let pairs : Array[String] = []
  for i in 1..<opts.positional.length() {
    pairs.push(opts.positional[i])
  }
  with_server(server, opts.timeout_ms, session => {
    let tools = session.list_tools(opts.timeout_ms)
    let tool = match find_tool(tools, tool_name) {
      Some(tool) => tool
      None =>
        raise fail(
          "'" +
          server_name +
          "' has no tool named '" +
          tool_name +
          "'" +
          available_tools(tools),
        )
    }
    let arguments = build_arguments(pairs, tool.input_schema)
    let result = session.call_tool(tool_name, arguments, opts.timeout_ms)
    print_line(render_call_output(result, opts))
    if result.is_error {
      raise fail("tool '\{tool_name}' reported an error")
    }
  })
}

///|
/// `mcpbox config [--json]`
async fn cmd_config(args : Array[String]) -> Unit raise Error {
  let opts = parse_options(args)
  if opts.help {
    print_line(help_text())
    return
  }
  let files = config_files()
  let all_servers = resolve_servers(opts)
  let servers : Array[Server] = []
  for server in all_servers {
    if server_matches_filters(server.name, opts.positional) {
      servers.push(server)
    }
  }
  if opts.json {
    let file_json : Array[Json] = []
    for file in files {
      file_json.push(
        Json::object({
          "path": Json::string(file.0),
          "servers": Json::number(file.1.to_double(), repr=file.1.to_string()),
        }),
      )
    }
    let server_json : Array[Json] = []
    for server in servers {
      server_json.push(server_to_json(server))
    }
    print_line(
      Json::object({
        "files": Json::array(file_json),
        "servers": Json::array(server_json),
      }).stringify(indent=2),
    )
    return
  }
  print_line("config files:")
  if files.length() == 0 {
    print_line("  (none found)")
  }
  for file in files {
    print_line("  \{file.0}  (\{file.1} servers)")
  }
  print_line("")
  print_line("servers:")
  if servers.length() == 0 {
    if all_servers.length() == 0 {
      print_line("  (none)")
    } else {
      print_line("  (no servers match the filter)")
    }
  }
  for server in servers {
    print_line(
      "  \{server.name}  \{transport_label(server)}  \{transport_target(server)}",
    )
  }
}

///|
/// The dispatch table.
pub async fn run(args : Array[String]) -> Unit raise Error {
  let argv = tail(args)
  if argv.length() == 0 {
    print_line(help_text())
    return
  }
  let command = argv[0]
  let rest = tail(argv)
  match command {
    "version" | "--version" | "-v" => print_line("mcpbox \{version}")
    "help" | "--help" | "-h" => print_line(help_text())
    "list" | "ls" | "tools" => cmd_list(rest)
    "call" => cmd_call(rest)
    "config" => cmd_config(rest)
    _ => raise fail("unknown command '\{command}' (try 'mcpbox help')")
  }
}

///|
/// The `mcpbox help` text.
pub fn help_text() -> String {
  let out = StringBuilder()
  out.write_string(
    "mcpbox \{version} — carry MCP tools into scripts and agents\n",
  )
  out.write_string("\n")
  out.write_string("Usage: mcpbox <command> [options]\n")
  out.write_string("\n")
  out.write_string("Commands:\n")
  out.write_string(
    "  list [server ...]              list configured servers and their tools\n",
  )
  out.write_string(
    "  call <server>.<tool> [args]    call a tool; args are key=value pairs\n",
  )
  out.write_string(
    "  config [filter ...]            show config files and resolved servers\n",
  )
  out.write_string("  version                        print the version\n")
  out.write_string("  help                           show this help\n")
  out.write_string("\n")
  out.write_string("Options:\n")
  out.write_string("  --json                 machine-readable output\n")
  out.write_string("  --brief                names only, for list\n")
  out.write_string("  --raw                  text content only, for call\n")
  out.write_string(
    "  --timeout <seconds>    per-request timeout (default 30)\n",
  )
  out.write_string(
    "  --http-url <url>       call an ad-hoc Streamable HTTP server\n",
  )
  out.write_string(
    "  --stdio <command>      call an ad-hoc stdio server, e.g. \"npx -y x\"\n",
  )
  out.write_string("  -h, --help             show this help\n")
  out.write_string("  -v, --version          print the version\n")
  out.write_string("\n")
  out.write_string("Call arguments:\n")
  out.write_string(
    "  key=value              value is coerced using the tool's schema\n",
  )
  out.write_string("  key:=<json>            value is taken as raw JSON\n")
  out.write_string(
    "  --                     stop option parsing; later words are arguments\n",
  )
  out.write_string("\n")
  out.write_string("Config:\n")
  out.write_string(
    "  mcpbox.json, .mcpbox.json, config/mcpbox.json, .mcpbox/config.json,\n",
  )
  out.write_string(
    "  ~/.mcpbox.json, ~/.config/mcpbox/config.json, plus servers imported from\n",
  )
  out.write_string(
    "  Cursor, Claude Code/Desktop, Windsurf and VS Code. Set MCPBOX_CONFIG to\n",
  )
  out.write_string("  override.\n")
  out.write_string(
    "  config filters match name substrings; * and ? are wildcards.\n",
  )
  out.to_string()
}
