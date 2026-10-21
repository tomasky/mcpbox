# `@tomasko/mcpbox`

The npm launcher for [`mcpbox`](https://github.com/tomasky/mcpbox) — a
self-contained MCP (Model Context Protocol) client CLI in the spirit of
`mcporter`, written in MoonBit.

```sh
npm install -g @tomasko/mcpbox
mcpbox list
mcpbox call playwright.browser_close
mcpbox call adhoc.echo --stdio "python3 echo_server.py" name=hi count=5
```

`mcpbox` discovers the MCP servers you already have configured — in `mcpbox`
files, Cursor, Claude Code/Desktop, Windsurf or VS Code — connects to them over
stdio or Streamable HTTP, and lists or calls their tools from a shell, a script
or an agent. One process, no daemon, no background state.

## Usage

### Discovering tools

`mcpbox list` connects to every configured server in parallel and prints the
tools each one advertises, with signatures:

```console
$ mcpbox list
github         npx -y @modelcontextprotocol/server-github  [github 1.0.0]
  create_issue(owner: string, repo: string, title: string, body?: string)
context7       https://mcp.context7.com/mcp  [context7 1.0.0]
  resolve-library-id(query: string)
```

- `mcpbox list github` only lists the named servers; repeat a name to select
  several.
- `mcpbox list --json` prints machine-readable output: `{"servers":[...]}` with
  each server's identity, `serverInfo`, `tools` and, on failure, an `error`
  field.
- `mcpbox list --brief` prints one line per server instead of the full tool
  table.
- A server that fails to start is reported as an error entry without hiding the
  others.

### Calling a tool

Targets are `<server>.<tool>`:

```sh
mcpbox call github.create_issue owner=acme repo=api title="Bug report" body="..."
mcpbox call context7.resolve-library-id query="React hooks docs"
```

Arguments are `key=value` pairs, coerced with the tool's `inputSchema`, so the
wire format gets the right JSON types without quoting:

| Argument | Schema says | Sent as |
| --- | --- | --- |
| `count=5` | integer/number | `5` |
| `flag=true` / `flag=false` | boolean | `true` / `false` |
| `name=hi` | string | `"hi"` (so `note="a, b"` stays one string) |
| `tags=a,b` | array | `["a","b"]` |
| `meta={"x":1}` / `meta:={"x":1}` | object | `{"x":1}` (`:=` skips coercion) |

- `key:=<json>` takes the value as raw JSON verbatim — use it when you know
  better than the schema (`data:=null`, `ids:=[1,2,3]`).
- `--` stops option parsing; everything after it is passed through as
  arguments. Useful when a shell would eat characters mcpbox would handle:
  `mcpbox call s.run -- cmd="ls -l"`. Empty strings work as values
  (`note=""`).
- Calling an unknown tool or server exits non-zero and lists what *was*
  available, so scripts fail loudly and agents can self-correct.

### Ad-hoc servers (no configuration file)

Point mcpbox at one server without touching any config file. The ad-hoc server
is named `adhoc`, so `call` may use the bare tool name or `adhoc.<tool>`:

```sh
# Streamable HTTP
mcpbox list --http-url https://mcp.context7.com/mcp
mcpbox call --http-url https://mcp.context7.com/mcp resolve-library-id \
  query="React hooks docs"

# stdio child process (the string is split like a shell)
mcpbox call adhoc.echo --stdio "python3 echo_server.py" name=hi count=5
```

Both transports honour `--timeout <seconds>` (default `30`), which applies to
each request, including the `initialize` handshake. Fractional seconds are
allowed (`--timeout 0.5`).

The HTTP transport sends `Accept: application/json, text/event-stream`,
manages the `Mcp-Session-Id` for you, decodes `gzip` responses, and follows
same-origin redirects with the standard 301/302/303/307/308 method rules — a
session-terminating `DELETE` keeps its method across a 301. `text/event-stream`
bodies are decoded event by event, so notifications before the answer are not
concatenated into invalid JSON.

### Inspecting configuration

`mcpbox config` shows the config files that exist, in precedence order, and the
resolved server set:

```console
$ mcpbox config --json 'gh*'
```

Filters match server-name substrings; `*` matches any sequence and `?` a single
character, and repeating a filter means "any of these":

```sh
mcpbox config              # everything, human-readable
mcpbox config github       # servers whose name contains "github"
mcpbox config 'gh*' 'cue*' # union of both patterns
mcpbox config --json       # {"files":[(...)],"servers":[(...)]}
```

### JSON everywhere

`--json` on `list`, `call` and `config` prints stable, parseable output; `--raw`
(`call`) prints the tool's text content without the JSON envelope. Combined
with the exit codes this makes mcpbox usable directly from `jq`, a Makefile or
an agent loop:

```sh
mcpbox call context7.resolve-library-id query=zustand --json | jq -r '.'
```

### Configuration files

mcpbox reads the same `mcpServers` blocks the other MCP clients use, so an
existing configuration works as-is. Files are JSONC: `//` and `/* */` comments
and trailing commas are accepted. Set `MCPBOX_CONFIG` to read one explicit file;
the value is trimmed and a leading `~` is expanded, so
`MCPBOX_CONFIG="~/mcp.json"` behaves like a layer below.

```json
{
  "mcpServers": {
    "context7": { "url": "https://mcp.context7.com/mcp" },
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": { "TOKEN": "${FS_TOKEN}" }
    }
  }
}
```

Precedence, first definition of a name wins:

1. `$MCPBOX_CONFIG`
2. `./mcpbox.json`, `./.mcpbox.json`, `./config/mcpbox.json`, `./.mcpbox/config.json`
3. `./.cursor/mcp.json`, `./.vscode/mcp.json`
4. `~/.mcpbox.json`
5. `~/.config/mcpbox/config.json`
6. `~/.cursor/mcp.json`, `~/.claude.json`,
   `~/.codeium/windsurf/mcp_config.json`,
   `~/.config/Claude/claude_desktop_config.json`,
   `~/Library/Application Support/Claude/claude_desktop_config.json`

String values support `${VAR}` and `${VAR:-fallback}` placeholders, and an
explicit stdio `cwd` is resolved against the config file that declares it, so
relative paths do not depend on the directory `mcpbox` was launched from.

Run `mcpbox help` for the full option list.

## What this package contains

A small launcher, not the binary itself. On the first `mcpbox` run it downloads
the prebuilt native binary for your platform from the GitHub release and caches
it. Nothing is downloaded at install time.

| Platform | Target |
| --- | --- |
| Linux x86-64 | `mcpbox-linux-x86_64` (static, musl) |
| Linux arm64 | `mcpbox-linux-aarch64` (static, musl) |
| macOS Apple silicon | `mcpbox-darwin-aarch64` |

The Linux builds are linked statically against musl, so they run on any
distribution regardless of its glibc version.

## Why there is no `postinstall`

This package deliberately declares **no install script**. Since npm 12,
dependency lifecycle scripts are blocked unless the user opts in; and pnpm 12
fails a *project* install outright with `ERR_PNPM_IGNORED_BUILDS` when a
dependency declares one:

```console
$ pnpm add @tomasko/mcpbox
Error: ERR_PNPM_IGNORED_BUILDS
  × adding a new package
  ╰─▶ Ignored build scripts: @tomasko/mcpbox@0.1.5
```

Downloading lazily from `bin/mcpbox.js` sidesteps all of it: it works under
npm, pnpm, yarn, bun, `npx`, and `--ignore-scripts`, because it is an ordinary
command rather than an install hook.

## Cache location

The downloaded binary is kept outside the package, so reinstalling or clearing
`node_modules` never triggers a second download:

| Platform | Path |
| --- | --- |
| Linux | `$XDG_CACHE_HOME/mcpbox` or `~/.cache/mcpbox` |
| macOS | `~/Library/Caches/mcpbox` |

## Environment variables

| Variable | Effect |
| --- | --- |
| `MCPBOX_BINARY` | Run this binary and never download anything |
| `MCPBOX_CACHE_DIR` | Where to keep the downloaded binary |
| `MCPBOX_VERSION` | Release version to fetch (default: this package's version) |
| `MCPBOX_REPO` | `owner/repo` to download from (default: `tomasky/mcpbox`) |
| `MCPBOX_DOWNLOAD_BASE` | Full base URL, overriding `MCPBOX_REPO`/`MCPBOX_VERSION` |
| `MCPBOX_FORCE_DOWNLOAD` | Re-download even if the cached binary exists |
| `MCPBOX_SKIP_DOWNLOAD` | Never download; fail if the binary is absent |
| `MCPBOX_NO_VERIFY` | Skip SHA-256 verification of the download |

`MCPBOX_DOWNLOAD_BASE` and `MCPBOX_REPO` are there for forks, private mirrors
and air-gapped installs:

```sh
MCPBOX_DOWNLOAD_BASE=https://internal.example.com/mcpbox npm install -g @tomasko/mcpbox
```

The CLI itself also reads `MCPBOX_CONFIG` to point at an explicit config file.

## Other ways to install

```sh
# Installer script (no Node.js required)
curl -LsSf https://raw.githubusercontent.com/tomasky/mcpbox/master/install.sh | bash

# Build from source
git clone https://github.com/tomasky/mcpbox && cd mcpbox
moon build --target native --release
```

## License

Apache-2.0
