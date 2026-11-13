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
echo "== legacy HTTP+SSE transport =="
SSE_PORT="${MCPBOX_SSE_PORT:-8767}"
SSE_LOG="$(mktemp)"
SSE_CONFIG="$(mktemp)"
SSE_MARKER="$(mktemp)"
python3 tests/fixtures/sse_server.py "$SSE_PORT" "$SSE_MARKER" >"$SSE_LOG" 2>&1 &
SSE_SERVER=$!
trap 'kill "$SERVER" "$SSE_SERVER" 2>/dev/null || true; rm -f "$MARKER" "$SERVER_LOG" "$CONFIG" "$SSE_LOG" "$SSE_CONFIG" "$SSE_MARKER"' EXIT
cat >"$SSE_CONFIG" <<JSON
{
  "mcpServers": {
    "legacy": {"type": "sse", "url": "http://127.0.0.1:$SSE_PORT/sse"}
  }
}
JSON
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1', $SSE_PORT), 0.2).close()" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
MCPBOX_CONFIG="$SSE_CONFIG" "$BIN" list legacy --brief --quiet | grep -q "legacy"
SSE_CALL="$(MCPBOX_CONFIG="$SSE_CONFIG" "$BIN" call legacy.echo name=sse --quiet)"
printf '%s\n' "$SSE_CALL" | grep -q '"name": "sse"' || {
  echo "error: legacy SSE tool call returned: $SSE_CALL" >&2
  cat "$SSE_LOG" >&2
  exit 1
}
# A server-initiated request on the stream must be answered, not ignored.
grep -q "srv-1" "$SSE_MARKER" || {
  echo "error: server request over SSE was not answered" >&2
  cat "$SSE_LOG" >&2
  exit 1
}

# The same server through the ad-hoc flag, without a config file.
"$BIN" list --sse-url "http://127.0.0.1:$SSE_PORT/sse" --json |
  grep -q '"name": "echo"'
"$BIN" call adhoc.echo --sse-url "http://127.0.0.1:$SSE_PORT/sse" name=adhoc \
  --quiet | grep -q '"name": "adhoc"'

# `?flaky=1` drops the stream during initialize and during tools/list. The
# client must reconnect, pick up the new endpoint, and replay the pending
# response; the second reconnect must carry the last event id it saw.
cat >"$SSE_CONFIG" <<JSON
{
  "mcpServers": {
    "flaky": {"type": "sse", "url": "http://127.0.0.1:$SSE_PORT/sse?flaky=1"}
  }
}
JSON
MCPBOX_CONFIG="$SSE_CONFIG" "$BIN" list flaky --json |
  grep -q '"name": "echo"'
# The initial stream plus one reconnect before any event id was seen; the last
# reconnect must replay the id of the dropped tools/list stream.
if [ "$(grep -c '^stream:' "$SSE_MARKER")" -ne 3 ] ||
  [ "$(grep '^stream:' "$SSE_MARKER" | tail -n 1)" != "stream:1" ]; then
  echo "error: SSE reconnect did not resend Last-Event-ID" >&2
  cat "$SSE_MARKER" >&2
  cat "$SSE_LOG" >&2
  exit 1
fi

# `?expire=1` forgets the session on the first tools/list and answers 404. The
# request was not accepted, so mcpbox reopens the stream and sends it once more.
cat >"$SSE_CONFIG" <<JSON
{
  "mcpServers": {
    "expired": {"type": "sse", "url": "http://127.0.0.1:$SSE_PORT/sse?expire=1"}
  }
}
JSON
MCPBOX_CONFIG="$SSE_CONFIG" "$BIN" list expired --json |
  grep -q '"name": "echo"'
grep -qx "expired" "$SSE_MARKER" || {
  echo "error: SSE 404 did not trigger a reconnect" >&2
  cat "$SSE_MARKER" >&2
  cat "$SSE_LOG" >&2
  exit 1
}
if grep -q '^uninitialized:' "$SSE_MARKER"; then
  echo "error: SSE 404 recovery reused the session without initializing" >&2
  cat "$SSE_MARKER" >&2
  cat "$SSE_LOG" >&2
  exit 1
fi

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
echo "== discovery starts nothing =="
DISCOVERED="$(MCPBOX_CONFIG="$CONFIG" "$BIN" list)"
printf '%s\n' "$DISCOVERED" | grep -qx alpha
printf '%s\n' "$DISCOVERED" | grep -qx beta
if printf '%s\n' "$DISCOVERED" | grep -q 'echo'; then
  echo "error: bare list contacted servers instead of only printing names" >&2
  printf '%s\n' "$DISCOVERED" >&2
  exit 1
fi

echo
echo "integration ok"
