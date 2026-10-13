#!/usr/bin/env python3
"""Hermitscale small-app recipe: Python standard library, isolated SQLite data."""
import argparse
import json
import os
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
    db.execute("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
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
        if self.path.split("?")[0] == "/api/notes":
            with database() as db:
                notes = [{"id": row[0], "body": row[1]} for row in db.execute("SELECT id, body FROM notes ORDER BY id DESC LIMIT 200")]
            return self.response(200, notes)
        if self.path.split("?")[0] != "/":
            return self.response(404, {"error": "Not found"})
        self.response(200, PAGE, "text/html; charset=utf-8")

    def do_POST(self):
        if self.path != "/api/notes":
            return self.response(404, {"error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self.response(400, {"error": "Invalid request length"})
        if not 0 < length <= 8192:
            return self.response(413, {"error": "Write a note under 8 KiB"})
        try:
            payload = json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return self.response(422, {"error": "Invalid note"})
        if not isinstance(payload, dict) or not isinstance(payload.get("body"), str):
            return self.response(422, {"error": "Write a text note"})
        body = payload["body"].strip()
        if not 0 < len(body) <= 2000:
            return self.response(422, {"error": "Write a note under 2000 characters"})
        with database() as db:
            cursor = db.execute("INSERT INTO notes (body) VALUES (?)", (body,))
            db.commit()
        self.response(201, {"id": cursor.lastrowid, "body": body})

    def log_message(self, message, *values):
        print(json.dumps({"event": "request", "method": self.command, "status": str(values[1]) if len(values) > 1 else "unknown"}), flush=True)

PAGE = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Notes</title><style>body{max-width:700px;margin:8vh auto;padding:24px;font:17px system-ui;color:#172b30;background:#f6f8f6}h1{font-size:44px;letter-spacing:-2px}form{display:flex;gap:12px}input{padding:15px;border:1px solid #cad7ce;border-radius:12px;flex:1;min-width:0;font:inherit}button{background:#174d3a;color:white;border:0;border-radius:12px;padding:15px;font:inherit;cursor:pointer}article{background:white;border-radius:14px;padding:20px;margin:14px 0;white-space:pre-wrap}p{color:#54665b}#status{min-height:24px}</style><main><p>YOUR APP</p><h1>A place for your notes.</h1><p>Published notes stay with this environment through updates.</p><form id="notes"><label for="body" hidden>New note</label><input id="body" name="body" required maxlength="2000" placeholder="What would you like to remember?"><button>Add note</button></form><p id="status" role="status"></p><section id="list" aria-label="Saved notes"></section></main><script>const form=document.querySelector('#notes'),list=document.querySelector('#list'),status=document.querySelector('#status');async function refresh(){const result=await fetch('api/notes');if(!result.ok)throw Error('Unable to load notes');list.replaceChildren(...(await result.json()).map(note=>{const item=document.createElement('article');item.textContent=note.body;return item}));}form.onsubmit=async(event)=>{event.preventDefault();const button=form.querySelector('button');button.disabled=true;status.textContent='Saving…';try{const response=await fetch('api/notes',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({body:form.elements.body.value})});if(!response.ok)throw Error('Unable to save note');form.reset();await refresh();status.textContent='Saved';}catch(error){status.textContent=error.message}finally{button.disabled=false}};refresh().catch(error=>status.textContent=error.message);</script></html>"""
database().close()
ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
