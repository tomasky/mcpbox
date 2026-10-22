# mcpbox 📦 — carry MCP tools into scripts, CLIs and agents

[![CI](https://github.com/tomasky/mcpbox/actions/workflows/ci.yml/badge.svg)](https://github.com/tomasky/mcpbox/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@tomasko/mcpbox?style=flat-square)](https://www.npmjs.com/package/@tomasko/mcpbox)
[![License](https://img.shields.io/github/license/tomasky/mcpbox?style=flat-square)](LICENSE)

mcpbox is a self-contained [Model Context Protocol](https://modelcontextprotocol.io)
client and command line, written in [MoonBit](https://www.moonbitlang.com). It
is for developers and coding agents that want the MCP tools they already have
configured — from Cursor, Claude Code/Desktop, Windsurf, VS Code or an mcpbox
file — available in a terminal, a script or a generated agent.

It is deliberately small: one-shot by default, with an optional keep-alive
daemon for repeated commands. No Node runtime is needed by mcpbox itself.

## Install

Try it without installing anything:

```sh
npx @tomasko/mcpbox --version
```

Install it for repeated use:

```sh
npm install -g @tomasko/mcpbox
# or
curl -LsSf https://raw.githubusercontent.com/tomasky/mcpbox/master/install.sh | bash
# or, with the MoonBit toolchain: builds from source into ~/.moon/bin
moon install kupas/mcpbox/cmd/mcpbox
```

## Quick start

List the servers mcpbox found. This only reads configuration and starts nothing:

```sh
mcpbox list
```

Start them and show the tools each one advertises:

```sh
mcpbox list --all
```

Call a tool. The first argument is `<server>.<tool>`; the rest are arguments:

```sh
mcpbox call context7.resolve-library-id query="React hooks docs" libraryName=react
```

Point it at a server you have not configured yet:

```sh
mcpbox list --http-url https://mcp.context7.com/mcp
mcpbox call adhoc.echo --stdio "python3 echo_server.py" name=hi count=5
```

## What makes it pleasant

- **Schema-aware arguments.** `count=5` becomes the JSON number `5`, `flag=true`
  a boolean and `tags=a,b` an array, using the tool's `inputSchema`. You only
  reach for JSON when you want to: `meta:={"any":"json"}`.
- **Fast discovery.** `mcpbox list` prints configured server names without
  starting any of them. `mcpbox list --all` starts them in parallel and shows
  their tools.
- **Documented discovery.** `mcpbox list <server>` and `mcpbox list --all` show
  tool descriptions and parameter docs, including choices and defaults. Use
  `--no-docs` for bare signatures.
- **Optional keep-alive.** `-b` keeps initialized sessions in a background
  process, avoiding repeated stdio server startup.
- **Stable JSON.** `--json` produces output meant to be parsed, while the
  default is meant to be read.
- **Real exit codes.** A failed call exits non-zero, so a script or an agent can
  tell the difference.
- **Two transports.** stdio child processes and Streamable HTTP, including
  `text/event-stream` responses, session ids, gzip decoding, and same-origin
  redirects that keep POST and DELETE semantics.

## Commands

| Command | Purpose |
| --- | --- |
| `mcpbox list [server ...]` | List configured server names; `--all` starts them and shows tools |
| `mcpbox call <server>.<tool> [key=value ...]` | Call a tool |
| `mcpbox config [filter ...]` | Show config files and the resolved server set |
| `mcpbox stop <server>` | Close kept-alive sessions with this name |
| `mcpbox stop all` | Close all kept-alive sessions and exit the daemon |
| `mcpbox version` | Print the version |
| `mcpbox help` | Show help |

Useful flags: `--all`, `-b` / `--background`, `--no-docs`, `--quiet` / `-q`,
`--json`, `--brief`, `--raw`, `--timeout <seconds>`,
`--http-url <url>`, `--stdio "<command>"`. A `--` stops option parsing so
option-like words after it remain tool arguments. `config` filters match name
substrings, with `*` matching any sequence and `?` one character; repeat the
filter to match any of several names.

## Documentation and startup

`mcpbox list` is configuration-only and instant: it prints server names without
starting anything. Naming a server (`mcpbox list ct7`) or passing `--all` starts
the selected servers. Human-readable tool listings then include JSDoc-style
descriptions and `@param` comments, plus server instructions when supplied.
JSON output keeps its existing structured format; `--brief` stays compact.

While servers start, a terminal gets a one-line spinner with elapsed seconds on
stderr. Pipes and CI logs get plain `mcpbox: connecting...` lines instead;
`--quiet` hides progress, and `--json` suppresses it automatically so
machine-readable output stays clean.

## Keep servers warm

```sh
mcpbox list ct7 -b                  # start once; keep the MCP session alive
mcpbox call ct7.query-docs libraryId=/facebook/react query="hooks"
mcpbox list ct7                    # reuse the running service automatically
mcpbox stop ct7                    # stop every warm session named ct7
mcpbox stop all                    # stop every session and the service itself
```

Without `-b` and without an existing service, commands remain one-shot. The
service is per-user; sessions are isolated by working directory, config override,
and server name. Changed transport settings or environment replace the warm
session. Each command sends its resolved config and environment rather than
relying on the service's original working directory.

The daemon serializes requests to avoid concurrent readers on an MCP stream.
A request that loses its response is **not retried**, since a tool may already
have performed side effects. After a transport error, the affected session is
dropped; the next command can open a new one.

IPC uses loopback TCP authenticated by a random secret in a private (0700)
directory: `$XDG_RUNTIME_DIR/mcpbox`, or `~/.cache/mcpbox/run` when unset.
Server stderr is appended to `daemon.log` there. Treat this log as potentially
sensitive. The daemon runs until `stop all`; `stop <server>` leaves it available.
Shutdown closes stdin, then sends TERM/KILL if a stdio child ignores EOF.
Background mode currently requires POSIX (Linux/macOS).

An agent skill is available at [`skills/mcpbox/SKILL.md`](skills/mcpbox/SKILL.md).
The standalone lifecycle regression script accepts an already-built binary:
`bash tests/daemon.sh /absolute/path/to/mcpbox`. It does not build anything.

## Configuration

mcpbox reads the same `mcpServers` blocks the other MCP clients use, so an
existing configuration works as-is. Files are JSONC: `//` and `/* */` comments
and trailing commas are accepted.

A minimal `mcpbox.json`:

```json
{
  "mcpServers": {
    "context7": {
      "url": "https://mcp.context7.com/mcp"
    },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": { "TOKEN": "${FS_TOKEN}" }
    }
  }
}
```

Files are read in precedence order, with the first definition of a name winning.
`MCPBOX_CONFIG` is trimmed and a leading `~` is expanded, so a quoted
`"~/mcp.json"` behaves like the layers below.

1. `$MCPBOX_CONFIG`
2. `./mcpbox.json`, `./.mcpbox.json`, `./config/mcpbox.json`, `./.mcpbox/config.json`
3. `./.cursor/mcp.json`, `./.vscode/mcp.json`
4. `~/.mcpbox.json`
5. `~/.config/mcpbox/config.json`
6. `~/.cursor/mcp.json`, `~/.claude.json`,
   `~/.codeium/windsurf/mcp_config.json`,
   `~/.config/Claude/claude_desktop_config.json`,
   `~/Library/Application Support/Claude/claude_desktop_config.json`

String values support `${VAR}` and `${VAR:-fallback}`, including placeholders
embedded inside a longer value. An unset variable with no fallback expands to
the empty string. An explicit stdio `cwd` is resolved against the config file
that declares it, so relative paths do not depend on where `mcpbox` was
launched.

## Build from source

```sh
moon build --target native --release
_build/native/release/build/cmd/mcpbox/mcpbox.exe --help
```

The release binaries are linked statically against musl on Linux, so they run
on any distribution regardless of its glibc version.

## Development

```sh
moon check --target native --deny-warn
moon test --target native
moon info && moon fmt
```

The stdio and HTTP transports are exercised end to end against the fixture
server in `tests/fixtures/echo_server.py`:

```sh
moon build --target native
_build/native/debug/build/cmd/mcpbox/mcpbox.exe list \
  --stdio "python3 tests/fixtures/echo_server.py"
```

## License

Apache-2.0
