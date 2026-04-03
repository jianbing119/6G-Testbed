#!/usr/bin/env python3
"""
MCP HTTP Bridge for the 6G AI Traffic Testbed.

Wraps any stdio-based MCP server and exposes it over HTTP so that
traffic traverses the network stack and is subject to tc/netem shaping.

Usage (stdio pass-through -- no bridging):
    python -m mcp_servers.http_bridge uvx alpaca-mcp-server serve

Usage (HTTP bridge -- for netem):
    python -m mcp_servers.http_bridge uvx alpaca-mcp-server serve --http

The ``--http``, ``--host=``, and ``--port=`` flags are consumed by the
bridge.  Everything else is treated as the wrapped MCP server command.

When launched with ``--http``, the bridge:
1. Spawns the wrapped command as a stdio subprocess
2. Starts a threaded HTTP server
3. Proxies each HTTP POST as a JSON-RPC message to the subprocess's
   stdin and reads the response from stdout
4. Prints ``PORT=<n>`` so the MCPHttpConnection can discover the port

This makes *any* third-party stdio MCP server compatible with the
testbed's HTTP transport (and therefore with netem on loopback).
"""

import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn


class _StdioProxy:
    """Proxies JSON-RPC messages to/from a stdio subprocess."""

    def __init__(self, cmd: list[str], env: dict | None = None):
        self._cmd = cmd
        proc_env = os.environ.copy()
        if env:
            proc_env.update(env)
        self._proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=proc_env,
            bufsize=0,
        )
        self._lock = threading.Lock()

    def send(self, request: dict) -> dict | None:
        """Send a JSON-RPC request/notification and return the response.

        For notifications (no ``id``), the subprocess may not send a
        response.  We detect this by the absence of ``id`` and return
        ``None`` immediately after writing.
        """
        data = json.dumps(request) + "\n"
        encoded = data.encode()

        with self._lock:
            self._proc.stdin.write(encoded)
            self._proc.stdin.flush()

            # Notifications have no id -- no response expected
            if "id" not in request:
                return None

            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError("Wrapped MCP server closed stdout")
            return json.loads(line.decode())

    def close(self):
        try:
            self._proc.terminate()
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()


# ---------------------------------------------------------------------------
# HTTP mode
# ---------------------------------------------------------------------------


def main_http(wrapped_cmd: list[str], host: str = "127.0.0.1", port: int = 0):
    proxy = _StdioProxy(wrapped_cmd)

    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True

    class BridgeHandler(BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                request = json.loads(body)
                response = proxy.send(request)

                if response is None:
                    self.send_response(204)
                    self.end_headers()
                    return

                payload = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except json.JSONDecodeError:
                error_resp = {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "Parse error"},
                }
                payload = json.dumps(error_resp).encode()
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        def log_message(self, fmt, *args):
            pass

    server = ThreadingHTTPServer((host, port), BridgeHandler)
    actual_port = server.server_address[1]
    sys.stdout.write(f"PORT={actual_port}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    finally:
        proxy.close()


# ---------------------------------------------------------------------------
# Stdio pass-through mode
# ---------------------------------------------------------------------------


def main_stdio(wrapped_cmd: list[str]):
    """Pass-through: relay stdin→subprocess→stdout."""
    proxy = _StdioProxy(wrapped_cmd)
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                response = proxy.send(request)
                if response is not None:
                    sys.stdout.write(json.dumps(response) + "\n")
                    sys.stdout.flush()
            except json.JSONDecodeError:
                error_resp = {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32700, "message": "Parse error"},
                }
                sys.stdout.write(json.dumps(error_resp) + "\n")
                sys.stdout.flush()
    finally:
        proxy.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main():
    args = sys.argv[1:]

    # Extract bridge flags from the argument list
    http_mode = False
    host = "127.0.0.1"
    port = 0
    wrapped_cmd: list[str] = []

    for arg in args:
        if arg == "--http":
            http_mode = True
        elif arg.startswith("--host="):
            host = arg.split("=", 1)[1]
        elif arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
        else:
            wrapped_cmd.append(arg)

    if not wrapped_cmd:
        print("Usage: python -m mcp_servers.http_bridge [--http] CMD [ARGS...]", file=sys.stderr)
        sys.exit(1)

    if http_mode:
        main_http(wrapped_cmd, host, port)
    else:
        main_stdio(wrapped_cmd)


if __name__ == "__main__":
    main()
