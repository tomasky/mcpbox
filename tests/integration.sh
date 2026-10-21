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
MARKER="$(mktemp)"
SERVER_LOG="$(mktemp)"
CONFIG="$(mktemp)"
cat >"$CONFIG" <<'JSON'
{
  "mcpServers": {
    "alpha": {"command": "echo"},
    "beta": {"command": "echo"}
  }
}
JSON
MCPBOX_MARKER="$MARKER" python3 tests/fixtures/http_server.py "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true; rm -f "$MARKER" "$SERVER_LOG" "$CONFIG"' EXIT
# Give the socket a moment to accept connections.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $PORT), 0.2).close()" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
"$BIN" list --http-url "http://127.0.0.1:$PORT/mcp"
"$BIN" call adhoc.echo --http-url "http://127.0.0.1:$PORT/mcp" name=hi
# A non-ASCII argument exercises UTF-8 Content-Length accounting.
"$BIN" call adhoc.echo --http-url "http://127.0.0.1:$PORT/mcp" "name=héllo 💩"

# A 307 redirect must keep the POST method and body.
"$BIN" list --http-url "http://127.0.0.1:$PORT/redirect"
"$BIN" call adhoc.echo --http-url "http://127.0.0.1:$PORT/redirect" name=redirected

# gzip responses are decoded, and several SSE events before the response are
# handled independently rather than concatenated.
"$BIN" list --http-url "http://127.0.0.1:$PORT/gzip"
"$BIN" call adhoc.echo --http-url "http://127.0.0.1:$PORT/sse" name=streamed

# A 301 must keep the session-termination DELETE. The server records the
# method it actually received at /current.
"$BIN" list --http-url "http://127.0.0.1:$PORT/old"
grep -q "delete:/current" "$MARKER" || {
  echo "error: DELETE did not survive the 301 redirect" >&2
  cat "$SERVER_LOG" >&2
  exit 1
}

echo
echo "== config filters =="
FILTERED="$(MCPBOX_CONFIG=" $CONFIG " "$BIN" config --json 'al*')"
printf '%s\n' "$FILTERED" | grep -q '"name": "alpha"' || {
  echo "error: config glob did not include alpha" >&2
  printf '%s\n' "$FILTERED" >&2
  exit 1
}
if printf '%s\n' "$FILTERED" | grep -q '"name": "beta"'; then
  echo "error: config glob leaked an unmatched server" >&2
  printf '%s\n' "$FILTERED" >&2
  exit 1
fi
printf '%s\n' "$FILTERED" | grep -q "$CONFIG" || {
  echo "error: trimmed MCPBOX_CONFIG path was not used" >&2
  printf '%s\n' "$FILTERED" >&2
  exit 1
}
MCPBOX_CONFIG="$CONFIG" "$BIN" config --json 'b?ta' | grep -q '"name": "beta"'

echo
echo "integration ok"
