"""A stand-in for Zharp: OTLP/JSON bodies (gunzipped) appended to <out>/received.jsonl, one per
line as {"path", "auth", "gzip", "body"}. Answers CORS preflights (the web export) and serves
static files from <static> (the web export) on the same port.
Usage: receiver.py <out> [port] [static]"""
import gzip
import http.server
import json
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 4318
STATIC = sys.argv[3] if len(sys.argv) > 3 else None
os.makedirs(OUT, exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=STATIC or OUT, **kwargs)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Cross-Origin-Resource-Policy", "cross-origin")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        # The game's own requests: their headers, to check traceparent and baggage.
        if not self.path.startswith("/web/"):
            with open(os.path.join(OUT, "requests.jsonl"), "a") as f:
                f.write(json.dumps({"path": self.path, "headers": dict(self.headers)}) + "\n")
        super().do_GET()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        gz = self.headers.get("Content-Encoding") == "gzip"
        if gz:
            body = gzip.decompress(body)
        entry = {"path": self.path, "auth": self.headers.get("Authorization", ""), "gzip": gz,
                 "body": json.loads(body or b"{}")}
        with open(os.path.join(OUT, "received.jsonl"), "a") as f:
            f.write(json.dumps(entry) + "\n")
        print("POST", self.path, len(body), flush=True)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
