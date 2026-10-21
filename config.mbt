///|
/// Configuration discovery and parsing.
///
/// mcpbox reads the same `mcpServers` blocks the other MCP clients use, so an
/// existing Cursor, Claude or VS Code configuration works without a rewrite.
/// Files are JSONC: `//` and `/* */` comments and trailing commas are accepted
/// and stripped before parsing.

///|
/// One config file mcpbox knows how to read. `key` is the object that holds
/// the server map: `mcpServers` everywhere except VS Code, which uses
/// `servers`.
priv struct Candidate {
  path : String
  key : String
}

///|
/// The user's home directory, or an empty string when it cannot be found.
fn home_dir() -> String {
  match @env.get_env_var("HOME") {
    Some(home) if home.length() > 0 => home
    _ =>
      match @env.get_env_var("USERPROFILE") {
        Some(profile) => profile
        None => ""
      }
  }
}

///|
/// Expand a leading `~` into the home directory.
fn expand_home(path : String) -> String {
  if path == "~" {
    return home_dir()
  }
  if path.has_prefix("~/") {
    return home_dir() + path[1:].to_owned()
  }
  path
}

///|
/// Resolve an explicitly configured path the way the config layers are
/// resolved: surrounding whitespace is ignorable and a quoted `~/...` expands
/// to the home directory.
fn resolve_config_path(path : String) -> String {
  expand_home(path.trim().to_owned())
}

///|
/// The directory holding a config file. Used to anchor relative `cwd` values
/// so a stdio server behaves the same no matter where mcpbox was launched.
fn config_directory(source : String) -> String {
  @path.Path(source).dirname().to_string()
}

///|
/// Resolve a stdio `cwd` against the config file that declared it. A leading
/// `~` expands to the home directory; relative paths are anchored at the
/// config file, not at the caller's working directory.
fn resolve_cwd(cwd : String, source : String) -> String {
  let trimmed = cwd.trim().to_owned()
  if trimmed.length() == 0 {
    return ""
  }
  let expanded = expand_home(trimmed)
  if @path.Path(expanded).is_absolute() {
    expanded
  } else {
    @path.Path(config_directory(source))
    .join(@path.Path(expanded))
    .normalize()
    .to_string()
  }
}

///|
/// Match one server name against a `config` filter. A filter without wildcards
/// is a substring match; `*` matches any sequence and `?` one character. The
/// wildcard form matches any substring too, using bounded dynamic programming
/// so a pathological pattern cannot backtrack exponentially.
fn server_matches_filter(name : String, filter : String) -> Bool {
  if !filter.contains("*") && !filter.contains("?") {
    return name.contains(filter)
  }
  let text = name.to_array()
  let pattern = filter.to_array()
  let m = pattern.length()
  if m == 0 {
    return true
  }
  let mut previous : Array[Bool] = Array::make(m + 1, false)
  previous[0] = true
  for i in 1..<(m + 1) {
    previous[i] = pattern[i - 1] == '*' && previous[i - 1]
  }
  if previous[m] {
    return true
  }
  for c in text {
    let current : Array[Bool] = Array::make(m + 1, false)
    current[0] = true
    for i in 1..<(m + 1) {
      let token = pattern[i - 1]
      current[i] = if token == '*' {
        current[i - 1] || previous[i]
      } else {
        previous[i - 1] && (token == '?' || token == c)
      }
    }
    if current[m] {
      return true
    }
    previous = current
  }
  false
}

///|
/// True when a server matches any of the filters (an empty list matches all).
fn server_matches_filters(name : String, filters : Array[String]) -> Bool {
  if filters.length() == 0 {
    return true
  }
  for filter in filters {
    if server_matches_filter(name, filter) {
      return true
    }
  }
  false
}

///|
/// The XDG config directory, falling back to `~/.config`.
fn config_home() -> String {
  match @env.get_env_var("XDG_CONFIG_HOME") {
    Some(dir) if dir.length() > 0 => dir
    _ => home_dir() + "/.config"
  }
}

///|
/// Candidate config files in precedence order: the first definition of a name
/// wins. Project-local files come before user-wide ones, and mcpbox's own
/// files before the ones imported from other clients.
fn config_candidates() -> Array[Candidate] {
  let home = home_dir()
  let xdg = config_home()
  let candidates : Array[Candidate] = []
  // An explicit path overrides everything else. Trim it and expand a leading
  // `~` so a quoted `--config`-style value works the same as the layers below.
  match @env.get_env_var("MCPBOX_CONFIG") {
    Some(path) if path.trim().length() > 0 =>
      candidates.push({ path: resolve_config_path(path), key: "mcpServers", })
    _ => ()
  }
  for
    path in [
      "./mcpbox.json", "./.mcpbox.json", "./config/mcpbox.json", "./.mcpbox/config.json",
      "./.cursor/mcp.json", "./.vscode/mcp.json",
    ] {
    candidates.push({
      path,
      key: if path == "./.vscode/mcp.json" {
        "servers"
      } else {
        "mcpServers"
      },
    })
  }
  candidates.push({ path: "\{home}/.mcpbox.json", key: "mcpServers", })
  candidates.push({ path: "\{xdg}/mcpbox/config.json", key: "mcpServers", })
  candidates.push({ path: "\{home}/.cursor/mcp.json", key: "mcpServers", })
  candidates.push({ path: "\{home}/.claude.json", key: "mcpServers", })
  candidates.push({
    path: "\{home}/.codeium/windsurf/mcp_config.json",
    key: "mcpServers",
  })
  candidates.push({
    path: "\{home}/.config/Claude/claude_desktop_config.json",
    key: "mcpServers",
  })
  candidates.push({
    path: "\{home}/Library/Application Support/Claude/claude_desktop_config.json",
    key: "mcpServers",
  })
  candidates
}

///|
/// Strip `//` and `/* */` comments from JSONC text, leaving string literals
/// untouched.
fn strip_jsonc_comments(text : String) -> String {
  let out = StringBuilder(size_hint=text.length())
  let chars = text.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_string = false
  while i < n {
    let c = chars[i]
    if in_string {
      out.write_char(c)
      if c == '\\' && i + 1 < n {
        out.write_char(chars[i + 1])
        i += 2
        continue
      }
      if c == '"' {
        in_string = false
      }
      i += 1
      continue
    }
    if c == '"' {
      in_string = true
      out.write_char(c)
      i += 1
      continue
    }
    if c == '/' && i + 1 < n {
      if chars[i + 1] == '/' {
        i += 2
        while i < n && chars[i] != '\n' {
          i += 1
        }
        continue
      }
      if chars[i + 1] == '*' {
        i += 2
        while i + 1 < n && !(chars[i] == '*' && chars[i + 1] == '/') {
          i += 1
        }
        i += 2
        continue
      }
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
/// Drop commas that sit directly before a closing brace or bracket, the other
/// concession JSONC makes to hand-written config.
fn strip_trailing_commas(text : String) -> String {
  let out = StringBuilder(size_hint=text.length())
  let chars = text.to_array()
  let n = chars.length()
  let mut i = 0
  let mut in_string = false
  while i < n {
    let c = chars[i]
    if in_string {
      out.write_char(c)
      if c == '\\' && i + 1 < n {
        out.write_char(chars[i + 1])
        i += 2
        continue
      }
      if c == '"' {
        in_string = false
      }
      i += 1
      continue
    }
    if c == '"' {
      in_string = true
      out.write_char(c)
      i += 1
      continue
    }
    if c == ',' {
      let mut j = i + 1
      while j < n && is_json_space(chars[j]) {
        j += 1
      }
      if j < n && (chars[j] == '}' || chars[j] == ']') {
        i += 1
        continue
      }
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
fn is_json_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

///|
/// Parse JSONC text into a `Json` value.
pub fn parse_jsonc(text : String) -> Json raise McpError {
  let cleaned = strip_trailing_commas(strip_jsonc_comments(text))
  @json.parse(cleaned) catch {
    e => raise fail("invalid JSON: \{e.to_string()}")
  }
}

///|
/// Expand `${VAR}` and `${VAR:-fallback}` in a string. An unset variable with
/// no fallback expands to the empty string rather than failing, so a missing
/// optional token does not make the whole config unreadable.
pub fn expand_env(text : String) -> String {
  let out = StringBuilder(size_hint=text.length())
  let chars = text.to_array()
  let n = chars.length()
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '$' && i + 1 < n && chars[i + 1] == '{' {
      let inner = StringBuilder()
      let mut j = i + 2
      while j < n && chars[j] != '}' {
        inner.write_char(chars[j])
        j += 1
      }
      if j < n {
        let expr = inner.to_string()
        let (name, fallback) = match expr.split_once(":-") {
          Some((name, fallback)) => (name.to_owned(), Some(fallback.to_owned()))
          None => (expr, None)
        }
        match @env.get_env_var(name) {
          Some(value) => out.write_string(value)
          None =>
            match fallback {
              Some(value) => out.write_string(value)
              None => ()
            }
        }
        i = j + 1
        continue
      }
      // An unterminated `${` is emitted literally.
      out.write_char('$')
      i += 1
      continue
    }
    out.write_char(c)
    i += 1
  }
  out.to_string()
}

///|
/// Read a string field, expanding environment references.
fn json_string(obj : Map[String, Json], key : String) -> String? {
  match obj.get(key) {
    Some(String(value)) => Some(expand_env(value))
    _ => None
  }
}

///|
/// Read a `Map[String, String]` field, expanding environment references in
/// both keys and values.
fn json_string_map(
  obj : Map[String, Json],
  key : String,
) -> Map[String, String] {
  let out : Map[String, String] = Map([])
  match obj.get(key) {
    Some(Object(entries)) =>
      for entry in entries {
        match entry {
          (k, String(v)) => out[expand_env(k)] = expand_env(v)
          (k, Number(n, ..)) => out[expand_env(k)] = n.to_string()
          (k, True) => out[expand_env(k)] = "true"
          (k, False) => out[expand_env(k)] = "false"
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Read a string array field, expanding environment references.
fn json_string_array(obj : Map[String, Json], key : String) -> Array[String] {
  let out : Array[String] = []
  match obj.get(key) {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(value) => out.push(expand_env(value))
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Parse one server definition. Both the mcporter-style `url`/`command`
/// shorthand and the `type`/`transport` form used by VS Code are accepted.
fn parse_server(
  name : String,
  json : Json,
  source : String,
) -> Server raise McpError {
  guard json is Object(obj) else {
    raise fail("\{source}: server '\{name}' must be an object")
  }
  let kind = match obj.get("transport") {
    Some(String(kind)) => Some(expand_env(kind))
    _ =>
      match obj.get("type") {
        Some(String(kind)) => Some(expand_env(kind))
        _ => None
      }
  }
  let url = json_string(obj, "url")
  let command = json_string(obj, "command")
  // `type`/`transport` disambiguates, but a definition with a `url` and no
  // command is unambiguous enough to infer.
  let use_http = match kind {
    Some(k) => k == "http" || k == "streamable-http" || k == "sse"
    None => url is Some(_) && command is None
  }
  if use_http {
    match url {
      Some(url) =>
        return {
          name,
          kind: Http({ url, headers: json_string_map(obj, "headers"), }),
          note: json_string(obj, "description").unwrap_or(source),
        }
      None => raise fail("\{source}: server '\{name}' is HTTP but has no 'url'")
    }
  }
  match command {
    Some(command) =>
      {
        name,
        kind: Stdio({
          command,
          args: json_string_array(obj, "args"),
          env: json_string_map(obj, "env"),
          cwd: match json_string(obj, "cwd") {
            Some(cwd) => resolve_cwd(cwd, source)
            None => ""
          },
        }),
        note: json_string(obj, "description").unwrap_or(source),
      }
    None =>
      raise fail(
        "\{source}: server '\{name}' needs a 'command' (stdio) or a 'url' (HTTP)",
      )
  }
}

///|
/// Extract the servers from one parsed config document. Returns an empty array
/// when the file has no server block, so an unrelated `mcp.json` is skipped
/// rather than reported as broken.
pub fn servers_from_document(
  json : Json,
  key : String,
  source : String,
) -> Array[Server] raise McpError {
  guard json is Object(root) else {
    raise fail("\{source}: the config root must be a JSON object")
  }
  match root.get(key) {
    None => []
    Some(Object(servers)) => {
      let out : Array[Server] = []
      for entry in servers {
        let (name, definition) = entry
        out.push(parse_server(name, definition, source))
      }
      out
    }
    Some(_) => raise fail("\{source}: '\{key}' must be a JSON object")
  }
}

///|
/// Load every server mcpbox can find. Names are deduplicated with the first
/// definition winning, matching the precedence of `config_candidates`.
pub async fn load_servers() -> Array[Server] raise McpError {
  let servers : Array[Server] = []
  let seen : Map[String, Unit] = Map([])
  for candidate in config_candidates() {
    let path = resolve_config_path(candidate.path)
    let exists = @fs.exists(path) catch { _ => false }
    if !exists {
      continue
    }
    let text = @fs.read_file(path).text() catch {
      e => raise fail("cannot read \{path}: \{e.to_string()}")
    }
    let document = parse_jsonc(text)
    let found = servers_from_document(document, candidate.key, path)
    for server in found {
      if !seen.contains(server.name) {
        seen[server.name] = ()
        servers.push(server)
      }
    }
  }
  servers
}

///|
/// The config files that exist on this machine, in precedence order, with the
/// number of servers each contributes. Used by `mcpbox config`.
pub async fn config_files() -> Array[(String, Int32)] raise McpError {
  let out : Array[(String, Int32)] = []
  for candidate in config_candidates() {
    let path = resolve_config_path(candidate.path)
    let exists = @fs.exists(path) catch { _ => false }
    if !exists {
      continue
    }
    let text = @fs.read_file(path).text() catch {
      e => raise fail("cannot read \{path}: \{e.to_string()}")
    }
    let document = parse_jsonc(text)
    let found = servers_from_document(document, candidate.key, path)
    out.push((path, found.length()))
  }
  out
}
