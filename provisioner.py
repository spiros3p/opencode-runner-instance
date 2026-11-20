#!/usr/bin/env python3
"""Repo commissioning service for the headless opencode runner.

One git URL -> one checkout under /workspace, kept forever. No re-clone on
repeat calls. Tasks themselves go through the native opencode HTTP API.

Auth: Authorization: Bearer $RUNNER_API_TOKEN on every route except /healthz.
"""
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

WORKSPACE = "/workspace"
HOME = os.environ.get("HOME", "/home/agent")
MANIFEST = os.path.join(HOME, ".config", "opencode-runner", "repos.json")
TOKEN = os.environ.get("RUNNER_API_TOKEN", "")
PORT = int(os.environ.get("PROVISIONER_PORT", "8300"))
MAX_BODY = 64 * 1024
LOCK = threading.Lock()

SCP = re.compile(r"^(?P<user>[A-Za-z0-9._-]+)@(?P<host>[A-Za-z0-9._-]+):(?P<path>.+)$")


def log(msg):
    print("[provisioner] %s" % msg, flush=True)


def key(url):
    m = SCP.match(url)
    if m:
        url = "ssh://%s@%s/%s" % (m.group("user"), m.group("host"), m.group("path"))
    return re.sub(r"\.git$", "", url.strip()).rstrip("/")


def valid_url(url):
    if not isinstance(url, str) or not url or "\n" in url or "\r" in url:
        return False
    if SCP.match(url):
        return True
    parts = urlsplit(url)
    return parts.scheme in ("https", "http", "ssh", "git") and bool(parts.netloc) and bool(parts.path.strip("/"))


def dir_name(url):
    m = SCP.match(url)
    path = m.group("path") if m else urlsplit(url).path
    name = path.rstrip("/").split("/")[-1]
    name = re.sub(r"\.git$", "", name)
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name).strip("-._")
    return name or "repo"


def load():
    try:
        with open(MANIFEST, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as exc:
        log("WARN: cannot read manifest: %s" % exc)
        return {}


def save(data):
    os.makedirs(os.path.dirname(MANIFEST), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="repos-", dir=os.path.dirname(MANIFEST))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, MANIFEST)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def unique_dir(name, rid, data):
    candidate = os.path.join(WORKSPACE, name)
    taken = {r["directory"] for r in data.values() if r.get("id") != rid}
    if candidate not in taken:
        return candidate
    short = rid[:6]
    attempt = 1
    while True:
        suffix = short if attempt == 1 else "%s-%d" % (short, attempt)
        candidate = os.path.join(WORKSPACE, "%s-%s" % (name, suffix))
        if candidate not in taken:
            return candidate
        attempt += 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    def reply(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        if not TOKEN:
            self.reply(500, {"error": "RUNNER_API_TOKEN not set"})
            return False
        want = "Bearer %s" % TOKEN
        if not hmac.compare_digest(self.headers.get("Authorization", ""), want):
            self.reply(401, {"error": "unauthorized"})
            return False
        return True

    def body(self):
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = -1
        if size < 0 or size > MAX_BODY:
            return None, "bad Content-Length"
        raw = self.rfile.read(size)
        try:
            return json.loads(raw or b"{}"), None
        except ValueError as exc:
            return None, "invalid JSON: %s" % exc

    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/healthz":
            return self.reply(200, {"ok": True})
        if not self.authed():
            return
        data = load()
        if path == "/repos":
            return self.reply(200, {"repos": [data[k] for k in sorted(data)]})
        if path.startswith("/repos/"):
            rec = data.get(path[len("/repos/"):])
            return self.reply(200, rec) if rec else self.reply(404, {"error": "unknown repo id"})
        return self.reply(404, {"error": "not found"})

    def do_POST(self):
        path = urlsplit(self.path).path
        if path != "/repos":
            return self.reply(404, {"error": "not found"})
        if not self.authed():
            return
        payload, err = self.body()
        if err:
            return self.reply(400, {"error": err})
        url = payload.get("url")
        if not valid_url(url):
            return self.reply(400, {"error": "url must be an https/ssh/git URL or git@host:path"})
        ref = payload.get("ref")
        if ref is not None and (not isinstance(ref, str) or not ref or "\n" in ref or "\r" in ref):
            return self.reply(400, {"error": "ref must be a short branch/tag name"})
        rid = hashlib.sha256(key(url).encode("utf-8")).hexdigest()[:12]

        with LOCK:
            data = load()
            if rid in data:
                return self.reply(200, dict(data[rid], created=False))
            name = dir_name(url)
            directory = unique_dir(name, rid, data)
            if os.path.exists(directory):
                return self.reply(409, {
                    "error": "target directory exists but is not registered",
                    "directory": directory,
                })
            cmd = ["git", "clone"]
            if ref:
                cmd += ["--branch", ref, "--single-branch"]
            cmd += ["--", url, directory]
            log("cloning %s -> %s" % (url, directory))
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
            except subprocess.TimeoutExpired:
                return self.reply(504, {"error": "git clone timed out"})
            if proc.returncode:
                log("clone failed: %s" % proc.stderr.strip()[-500:])
                return self.reply(500, {"error": "git clone failed", "detail": proc.stderr[-2000:]})
            rec = {
                "id": rid,
                "url": url,
                "ref": ref,
                "name": name,
                "directory": directory,
            }
            data[rid] = rec
            save(data)
            return self.reply(201, dict(rec, created=True))


def main():
    if not TOKEN:
        log("WARN: RUNNER_API_TOKEN empty; all routes except /healthz will 500")
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("listening on 0.0.0.0:%d, manifest %s" % (PORT, MANIFEST))
    server.serve_forever()


if __name__ == "__main__":
    main()
