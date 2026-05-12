#!/usr/bin/env python3
# Minimal HTTP backend used by the redirector tests.
# Echoes the request path and User-Agent so the runner can verify
# that the redirector preserves both.

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class H(BaseHTTPRequestHandler):
    def _resp(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("X-Backend", "real")
        self.end_headers()
        ua = self.headers.get("User-Agent", "")
        host = self.headers.get("Host", "")
        self.wfile.write(f"backend-ok path={self.path} host={host} ua={ua}\n".encode())

    def do_GET(self):
        self._resp()

    def do_POST(self):
        self._resp()

    def log_message(self, *a, **k):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    HTTPServer((host, port), H).serve_forever()
