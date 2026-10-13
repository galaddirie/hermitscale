#!/usr/bin/env python3
"""Hermitscale small-app recipe: Python standard library, isolated SQLite data."""
import argparse
import json
import sqlite3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--data-dir", default="/workspace/preview-data")
parser.add_argument("--revision", default="development")
parser.add_argument("--port", type=int, default=8080)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
data = Path(args.data_dir)
data.mkdir(parents=True, exist_ok=True)
(data / "uploads").mkdir(exist_ok=True)

def database():
    db = sqlite3.connect(str(data / "app.sqlite"), timeout=15)
    db.execute("PRAGMA journal_mode=WAL")
    db.commit()
    return db

if args.check:
    with database() as db:
        assert db.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    raise SystemExit(0)

class Handler(BaseHTTPRequestHandler):
    def response(self, status, content, content_type="application/json"):
        payload = content.encode() if isinstance(content, str) else json.dumps(content).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Hermitscale-Revision", args.revision)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.split("?")[0] == "/__hermitscale/health":
            with database() as db:
                result = db.execute("PRAGMA quick_check").fetchone()[0]
            return self.response(200 if result == "ok" else 503, {"revision": args.revision, "database": result})
        if self.path.split("?")[0] != "/":
            return self.response(404, {"error": "Not found"})
        self.response(200, PAGE, "text/html; charset=utf-8")

    def log_message(self, message, *values):
        print(json.dumps({"event": "request", "method": self.command, "status": str(values[1]) if len(values) > 1 else "unknown"}), flush=True)

PAGE = """<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Your app</title>
<main><h1>Your app is ready</h1></main>
</html>"""
database().close()
ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
