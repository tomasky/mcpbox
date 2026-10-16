#!/usr/bin/env bash
#
# End-to-end check of both transports against the fixture servers in
# `tests/fixtures`. Run from the repository root after a native build:
#
#     moon build --target native
#     tests/integration.sh
#
# The stdio fixture is a real MCP server over stdin/stdout; the HTTP fixture
# is a minimal Streamable HTTP server. Both are Python so the check does not
# depend on any particular MCP implementation being installed.
set -euo pipefail

BIN="${MCPBOX_BIN:-_build/native/debug/build/cmd/mcpbox/mcpbox.exe}"
PORT="${MCPBOX_TEST_PORT:-8765}"

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found; run 'moon build --target native' first" >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to run the fixture servers" >&2
  exit 1
}

echo "== stdio transport =="
"$BIN" list --stdio "python3 tests/fixtures/echo_server.py"
"$BIN" call adhoc.echo --stdio "python3 tests/fixtures/echo_server.py" \
  name=hi count=5 ratio=1.5 flag=true tags=a,b

echo
echo "== HTTP transport =="
python3 tests/fixtures/http_server.py "$PORT" &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT
# Give the socket a moment to accept connections.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $PORT), 0.2).close()" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
"$BIN" list --http-url "http://127.0.0.1:$PORT/mcp"
"$BIN" call adhoc.echo --http-url "http://127.0.0.1:$PORT/mcp" name=hi

echo
echo "integration ok"
