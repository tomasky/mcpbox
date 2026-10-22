---
name: mcpbox
description: Discover and call configured MCP tools from the terminal using mcpbox. Use for listing tool documentation, schema-aware tool calls, keeping MCP servers warm with -b, and stopping background sessions.
---

# mcpbox

Use the installed `mcpbox` binary. Do not build or install dependencies unless
asked. Config discovery imports existing MCP settings from mcpbox, Cursor,
Claude, Windsurf and VS Code; `MCPBOX_CONFIG` selects an explicit JSONC config.

## Discover before calling

```sh
mcpbox config
mcpbox list
mcpbox list ct7
mcpbox list --all
```

`list` without arguments only prints configured server names and starts
nothing. Use `list <server>` to start one server and show its tools, or
`list --all` to start every configured server. These listing forms show
signatures, tool descriptions and `@param` docs. Read them before choosing a
tool or its arguments. Do not guess library identifiers or required fields. Use
`--no-docs` for signatures only, `--brief` for server counts, or `--json` for
structured tool schemas.

## Call tools

```sh
mcpbox call ct7.resolve-library-id libraryName=react query="React hooks docs"
# Set LIBRARY_ID to the identifier returned above, not a guessed identifier:
mcpbox call ct7.query-docs libraryId="$LIBRARY_ID" query="useEffect cleanup"
```

Targets are `<server>.<tool>`. Arguments are `key=value`, coerced using the tool
schema: integers, numbers, booleans, arrays and objects. Shell-quote values with
spaces. For an exact JSON value, quote the whole `key:=<json>` argument:

```sh
mcpbox call server.tool 'options:={"limit":5}' 'tags:=["a","b"]'
```

Use `--raw` for text content only or `--json` for a structured MCP result. Use
`--timeout 60` for slow requests. A tool-reported error exits nonzero. Never
blindly retry a side-effecting call after a timeout or a disconnected daemon:
it may already have executed.

## Keep servers warm

```sh
mcpbox list ct7 -b
mcpbox call ct7.query-docs libraryId="$LIBRARY_ID" query="hooks"
mcpbox stop ct7
```

`-b` / `--background` starts the optional per-user service and retains initialized
MCP sessions. Later `list`/`call` commands reuse it without repeating `-b`.
Without a running service and without `-b`, commands are one-shot.

`stop ct7` closes warm sessions named ct7 across project scopes but leaves the
service running. `stop all` closes every session and exits the service: use it
only when asked or when you own all those sessions, since other commands may
share the service. Sessions use the requesting command's config, cwd and
environment; changed settings cause a new session. Requests are serialized.

Startup messages go to stderr. Use `--quiet` / `-q` to hide them; `--json`
suppresses progress automatically. POSIX background state and `daemon.log` live
in `$XDG_RUNTIME_DIR/mcpbox` or `~/.cache/mcpbox/run`. Logs may contain sensitive
server output; do not print or share them without reviewing/redacting secrets.

## Ad-hoc servers

```sh
mcpbox list --http-url https://example.com/mcp
mcpbox list --stdio "python3 /absolute/path/server.py"
mcpbox call adhoc.echo --stdio "python3 /absolute/path/server.py" name=hello
```

Only execute server commands the user trusts. A `--` stops flag parsing so later
words remain literal tool arguments. Consult `mcpbox help` for the full CLI.
