// mcpbox — a self-contained MCP (Model Context Protocol) client CLI.
//
// It discovers MCP servers from the usual config locations, connects to them
// over stdio or Streamable HTTP, and lists or calls their tools from a shell,
// a script or an agent. The design is deliberately closer to a small UNIX
// utility than to a framework: one process, no daemon, no background state.
//
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "kupas/mcpbox"

version = "0.1.3"

readme = "README.mbt.md"

repository = "https://github.com/tomasky/mcpbox"

license = "Apache-2.0"

keywords = [
  "mcp",
  "model-context-protocol",
  "cli",
  "client",
  "agent",
  "moonbit",
]

description = "A self-contained MCP client CLI for discovering and calling Model Context Protocol servers"

preferred_target = "native"

import {
  "moonbitlang/async@0.22.4",
  "moonbitlang/x@0.5.5",
}
