# mcpbox 📦 — carry MCP tools into scripts, CLIs and agents

[![CI](https://github.com/tomasky/mcpbox/actions/workflows/ci.yml/badge.svg)](https://github.com/tomasky/mcpbox/actions/workflows/ci.yml)
[![npm](https://img.shields.io/npm/v/@tomasko/mcpbox?style=flat-square)](https://www.npmjs.com/package/@tomasko/mcpbox)
[![License](https://img.shields.io/github/license/tomasky/mcpbox?style=flat-square)](LICENSE)

mcpbox is a self-contained [Model Context Protocol](https://modelcontextprotocol.io)
client and command line, written in [MoonBit](https://www.moonbitlang.com). It
is for developers and coding agents that want the MCP tools they already have
configured — from Cursor, Claude Code/Desktop, Windsurf, VS Code or an mcpbox
file — available in a terminal, a script or a generated agent.

It is deliberately small and stateless: one process, no daemon, no background
service, no Node runtime at execution time.

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
```

## Quick start

List the servers mcpbox found, and the tools each one advertises:

```sh
mcpbox list
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
- **Parallel discovery.** `mcpbox list` connects to every server at once, and a
  server that fails to start is reported without hiding the others.
- **Stable JSON.** `--json` produces output meant to be parsed, while the
  default is meant to be read.
- **Real exit codes.** A failed call exits non-zero, so a script or an agent can
  tell the difference.
- **Two transports.** stdio child processes and Streamable HTTP, including
  `text/event-stream` responses and session ids.

## Commands

| Command | Purpose |
| --- | --- |
| `mcpbox list [server ...]` | Discover servers and list their tools |
| `mcpbox call <server>.<tool> [key=value ...]` | Call a tool |
| `mcpbox config` | Show config files and the resolved server set |
| `mcpbox version` | Print the version |
| `mcpbox help` | Show help |

Useful flags: `--json`, `--brief`, `--raw`, `--timeout <seconds>`,
`--http-url <url>`, `--stdio "<command>"`.

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

Files are read in precedence order, with the first definition of a name winning:

1. `$MCPBOX_CONFIG`
2. `./mcpbox.json`, `./.mcpbox.json`, `./config/mcpbox.json`, `./.mcpbox/config.json`
3. `./.cursor/mcp.json`, `./.vscode/mcp.json`
4. `~/.config/mcpbox/config.json`
5. `~/.cursor/mcp.json`, `~/.claude.json`,
   `~/.codeium/windsurf/mcp_config.json`,
   `~/.config/Claude/claude_desktop_config.json`,
   `~/Library/Application Support/Claude/claude_desktop_config.json`

String values support `${VAR}` and `${VAR:-fallback}`. An unset variable with
no fallback expands to the empty string.

## Build from source

```sh
moon build --target native --release
_build/native/release/build/cmd/main/main.exe --help
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
_build/native/debug/build/cmd/main/main.exe list \
  --stdio "python3 tests/fixtures/echo_server.py"
```

## License

Apache-2.0
