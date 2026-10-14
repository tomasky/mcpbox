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
  ╰─▶ Ignored build scripts: @tomasko/mcpbox@0.1.1
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
