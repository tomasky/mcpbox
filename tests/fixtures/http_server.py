#!/usr/bin/env python3
"""A minimal Streamable HTTP MCP server used by mcpbox's integration checks.

It answers POSTed JSON-RPC on `/mcp`, returns `application/json`, and hands
back an `Mcp-Session-Id` on `initialize` so the session-id path is exercised.
Pass a port as the first argument; it defaults to 8765.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            message = json.loads(body)
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return

        method = message.get("method")
        request_id = message.get("id")

        if method == "notifications/initialized":
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

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
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "method not found"},
            }
        else:
            response = {"jsonrpc": "2.0", "id": request_id, "result": result}

        payload = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Mcp-Session-Id", "test-session")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
