#!/usr/bin/env python3
"""A minimal Streamable HTTP MCP server used by mcpbox's integration checks.

It answers POSTed JSON-RPC on `/mcp`, returns `application/json`, and hands
back an `Mcp-Session-Id` on `initialize` so the session-id path is exercised.
Pass a port as the first argument; it defaults to 8765.

Additional paths exercise transport behaviour that unit tests cannot reach:

* `/redirect` answers 307 and points at `/mcp`, so a POST keeps its method and
  body across the redirect.
* `/old` answers 301 and points at `/current`, so the session-termination
  DELETE keeps its method; the fixture records it in `MCPBOX_MARKER`.
* `/gzip` compresses the JSON response when the client advertises gzip.
* `/sse` sends a notification event before the response event.
"""

import gzip
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MARKER = os.environ.get("MCPBOX_MARKER", "")


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
            "serverInfo": {"name": "http-echo", "version": "1.0.0"},
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

    def read_message(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if not body:
            return None
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return None

    def do_POST(self):
        message = self.read_message()
        if message is None:
            if not self.headers.get("Content-Length"):
                self.send_response(400)
                self.send_header("Content-Length", "0")
                self.end_headers()
            return

        path = self.path.split("?", 1)[0]
        if path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "/mcp")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if message.get("method") == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        response = mcp_response(message)
        payload = json.dumps(response).encode()

        if path == "/sse":
            # A notification event before the actual response. Joining the
            # events into one JSON document would make the client fail.
            event = (
                b'event: message\ndata: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","data":"hello"}}\n\n'
                b"event: message\ndata: " + payload + b"\n\n"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(event)))
            self.send_header("Mcp-Session-Id", "test-session")
            self.end_headers()
            self.wfile.write(event)
            return

        if path == "/gzip":
            payload = gzip.compress(payload)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Mcp-Session-Id", "test-session")
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "test-session")
        self.end_headers()
        self.wfile.write(payload)

    def do_DELETE(self):
        path = self.path.split("?", 1)[0]
        if path == "/old":
            record("delete:/old")
            self.send_response(301)
            self.send_header("Location", "/current")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/current":
            record("delete:/current")
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/redirect":
            record("delete:/redirect")
            self.send_response(307)
            self.send_header("Location", "/mcp")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        record("delete:" + path)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
