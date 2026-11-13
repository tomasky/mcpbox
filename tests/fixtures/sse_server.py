#!/usr/bin/env python3
"""A minimal legacy HTTP+SSE MCP server used by mcpbox's integration checks.

The pre-Streamable-HTTP transport works differently from a POST endpoint:

* `GET /sse` answers with `text/event-stream` and immediately sends
  `event: endpoint` / `data: /messages?sessionId=...`, then keeps the
  connection open.
* JSON-RPC messages are POSTed to that endpoint and answered on the event
  stream with `event: message`.

The fixture advertises one `echo` tool, so both tool discovery and calls can
be checked without a real MCP implementation.

`GET /sse?flaky=1` drops the stream once on `initialize` and once on
`tools/list`, replaying each stashed response on the next stream. That makes
the client reconnect mid-session, refresh the endpoint, and send
`Last-Event-ID`. `GET /sse?expire=1` forgets the session when the first
`tools/list` arrives and answers it with 404, so a client must reopen the
stream and resend the request.
"""

import json
import queue
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

SESSIONS = {}
LOCK = threading.Lock()
MARKER = sys.argv[2] if len(sys.argv) > 2 else ""
SESSION_SEQ = 0
# Responses whose stream was dropped, replayed on the next flaky stream.
PENDING = []
DROPPED = set()
EXPIRED = False


def record(line):
    if not MARKER:
        return
    with open(MARKER, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def mcp_response(message):
    method = message.get("method")
    request_id = message.get("id")

    if method == "initialize":
        result = {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "sse-echo", "version": "1.0.0"},
        }
    elif method == "tools/list":
        result = {
            "tools": [{
                "name": "echo",
                "description": "Echo the arguments back",
                "inputSchema": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                    "required": ["name"],
                },
            }],
        }
    elif method == "tools/call":
        arguments = message.get("params", {}).get("arguments", {})
        result = {
            "content": [{
                "type": "text",
                "text": json.dumps(arguments, sort_keys=True),
            }],
        }
    else:
        result = None

    if result is None:
        return {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": {"code": -32601, "message": "method not found"},
        }
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        global SESSION_SEQ
        path = self.path.split("?", 1)[0]
        if path != "/sse":
            self.send_error(404, "not found")
            return

        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        params = parse_qs(query)
        flaky = params.get("flaky", [""])[0] == "1"
        expire = params.get("expire", [""])[0] == "1"

        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        events = queue.Queue()
        with LOCK:
            SESSION_SEQ += 1
            session_id = f"session-{SESSION_SEQ}"
            SESSIONS[session_id] = {
                "events": events,
                "flaky": flaky,
                "expire": expire,
                "initialized": False,
            }
        if flaky:
            last_id = self.headers.get("Last-Event-ID", "")
            record("stream:" + (last_id if last_id else "-"))

        def send_chunk(data):
            body = data.encode("utf-8")
            self.wfile.write(b"%x\r\n" % len(body) + body + b"\r\n")
            self.wfile.flush()

        def send_message(payload):
            rpc_id = json.loads(payload).get("id")
            id_line = f"id: {rpc_id}\n" if isinstance(rpc_id, int) else ""
            send_chunk("event: message\n" + id_line + "data: " + payload + "\n\n")

        try:
            send_chunk(
                "event: endpoint\n"
                f"data: /messages?sessionId={session_id}\n\n"
            )
            if flaky:
                with LOCK:
                    pending = list(PENDING)
                    PENDING.clear()
                for payload in pending:
                    send_message(payload)
            while True:
                try:
                    payload = events.get(timeout=0.2)
                except queue.Empty:
                    continue
                if payload is None:
                    # End the chunked body cleanly so the client sees EOF.
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
                    return
                send_message(payload)
        except (BrokenPipeError, ConnectionResetError):
            return
        finally:
            with LOCK:
                SESSIONS.pop(session_id, None)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        session_id = ""
        if "?" in self.path:
            query = self.path.split("?", 1)[1]
            for part in query.split("&"):
                key, _, value = part.partition("=")
                if key == "sessionId":
                    session_id = value
        if path != "/messages":
            self.send_error(404, "not found")
            return
        with LOCK:
            session = SESSIONS.get(session_id)
        if session is None:
            self.send_error(404, "unknown session")
            return
        events = session["events"]

        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            message = json.loads(body)
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return

        if session["expire"] and message.get("method") == "tools/list":
            global EXPIRED
            with LOCK:
                forget = not EXPIRED
                if forget:
                    EXPIRED = True
                    SESSIONS.pop(session_id, None)
            if forget:
                record("expired")
                self.send_error(404, "unknown session")
                return

        self.send_response(202)
        self.send_header("Content-Length", "0")
        self.end_headers()

        method = message.get("method")
        if method == "initialize":
            session["initialized"] = True
        if method == "notifications/initialized":
            return
        if message.get("id") == "srv-1" and "error" in message:
            record("srv-1")
            return
        if message.get("id") is not None:
            # `?expire=1` also models a server that refuses work on a session
            # that has not been initialized, so the client must handshake
            # again after reconnecting, not just resend the request.
            if session["expire"] and not session["initialized"]:
                record("uninitialized:" + str(method))
                events.put(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "error": {
                        "code": -32002,
                        "message": "server not initialized",
                    },
                }))
                return
            response = json.dumps(mcp_response(message))
            drop = False
            if session["flaky"] and method in ("initialize", "tools/list"):
                global DROPPED
                with LOCK:
                    if method not in DROPPED:
                        DROPPED.add(method)
                        PENDING.append(response)
                        drop = True
            if drop:
                events.put(None)
                return
            if method == "tools/call":
                # A server-initiated request arriving before the response must
                # be answered by the client instead of being dropped.
                events.put(json.dumps({
                    "jsonrpc": "2.0",
                    "id": "srv-1",
                    "method": "ping",
                }))
            events.put(response)

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8767
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
