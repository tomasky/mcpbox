#!/usr/bin/env python3
"""A minimal MCP stdio server used by mcpbox's integration checks.

It advertises one `echo` tool whose schema exercises every JSON type mcpbox
coerces, and replies with the arguments it received as JSON text. That makes
the coercion behaviour observable without a network or a real MCP server.
"""

import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            message = json.loads(raw)
        except json.JSONDecodeError:
            continue
        method = message.get("method")
        request_id = message.get("id")
        if method == "initialize":
            send({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "echo", "version": "1.0.0"},
                },
            })
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            send({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "tools": [{
                        "name": "echo",
                        "description": "Echo the arguments back as JSON",
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "count": {"type": "integer"},
                                "ratio": {"type": "number"},
                                "flag": {"type": "boolean"},
                                "tags": {"type": "array", "items": {"type": "string"}},
                                "meta": {"type": "object"},
                            },
                            "required": ["name"],
                        },
                    }],
                },
            })
        elif method == "tools/call":
            arguments = message.get("params", {}).get("arguments", {})
            send({
                "jsonrpc": "2.0",
                "id": request_id,
                "result": {
                    "content": [{
                        "type": "text",
                        "text": json.dumps(arguments, sort_keys=True),
                    }],
                },
            })
        elif request_id is not None:
            send({
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "method not found"},
            })


if __name__ == "__main__":
    main()
