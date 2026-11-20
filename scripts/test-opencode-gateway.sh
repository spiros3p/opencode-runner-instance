#!/usr/bin/env bash
# Hand-run tests for scripts/opencode-gateway. No network, no container.
# Spins a stub upstream (python) and drives the gateway with curl.
# Ports and the stub mode file are unique per run, so parallel runs of this
# suite do not collide.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
MODE_FILE="$(mktemp /tmp/gw-mode.XXXXXX)"
export GW_MODE_FILE="$MODE_FILE"
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
GW_LISTEN_PORT="$(free_port)"
GW_UPSTREAM_PORT="$(free_port)"
export GW_LISTEN_PORT GW_UPSTREAM_PORT
GW="http://127.0.0.1:$GW_LISTEN_PORT"
trap 'rm -rf "$T"; rm -f "$MODE_FILE"; kill $STUB_PID $GW_PID 2>/dev/null || true' EXIT

cat > "$T/stub.py" <<'EOF'
import json, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
def mode():
    try:
        return open(os.environ.get('GW_MODE_FILE', '/tmp/gw-mode.txt')).read().strip()
    except OSError:
        return 'settled'
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def _send(self, st, obj):
        body = json.dumps(obj).encode()
        self.send_response(st); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        if self.path == '/api/health':
            return self._send(200, {'healthy': True})
        if self.path == '/stream':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            self.wfile.write(b'5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n')
            return
        if self.path == '/echo':
            n = int(self.headers.get('Content-Length') or 0)
            data = self.rfile.read(n) if n else b''
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith('/api/session/missing/message'):
            return self._send(404, {'_tag': 'SessionNotFoundError'})
        if self.path.startswith('/api/session/') and self.path.endswith('/message?order=desc&limit=10'):
            if mode() == 'settled':
                return self._send(200, {'data': [{'type': 'assistant', 'finish': 'stop', 'content': [{'type': 'text', 'text': 'OK'}]}, {'type': 'user'}]})
            return self._send(200, {'data': [{'type': 'user'}]})
        return self._send(404, {'_tag': 'NotFound'})
    do_POST = do_GET
    do_PUT = do_GET
ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('GW_UPSTREAM_PORT', '18097'))), H).serve_forever()
EOF

fail() { echo "FAIL: $1" >&2; exit 1; }

python3 "$T/stub.py" & STUB_PID=$!
OPENCODE_SERVER_USERNAME=opencode OPENCODE_SERVER_PASSWORD=test-secret-123 \
  GATEWAY_LISTEN_PORT="$GW_LISTEN_PORT" GATEWAY_UPSTREAM_PORT="$GW_UPSTREAM_PORT" \
  WAIT_TIMEOUT_SECONDS=6 WAIT_POLL_SECONDS=0.2 \
  python3 "$HERE/opencode-gateway" & GW_PID=$!
for _ in $(seq 1 50); do
  curl -fsS -u opencode:test-secret-123 "$GW/api/health" >/dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS -u opencode:test-secret-123 "$GW/api/health" >/dev/null || fail "gateway did not come up"

# 1. no auth -> 401 (backend never sees it)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$GW/api/health")
[ "$CODE" = "401" ] || fail "expected 401 without auth, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -u opencode:wrong "$GW/api/health")
[ "$CODE" = "401" ] || fail "expected 401 with wrong password, got $CODE"

# 2. passthrough works with auth
BODY=$(curl -fsS -u opencode:test-secret-123 "$GW/api/health")
[ "$BODY" = '{"healthy": true}' ] || fail "passthrough body mismatch: $BODY"

# 3. wait on settled session -> fast 204 (proves the 503 stub is gone)
echo -n settled > "$MODE_FILE"
START=$(date +%s)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -u opencode:test-secret-123 "$GW/api/session/ses_test123/wait")
[ "$CODE" = "204" ] || fail "expected 204 for settled wait, got $CODE"
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -u opencode:test-secret-123 "$GW/api/session/ses_test123/wait/")
[ "$CODE" = "204" ] || fail "expected 204 for trailing-slash wait, got $CODE"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 5 ] || fail "settled wait took too long: ${ELAPSED}s"

# 4. wait on missing session -> 404
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -u opencode:test-secret-123 "$GW/api/session/missing/wait")
[ "$CODE" = "404" ] || fail "expected 404 for missing session wait, got $CODE"

# 5. wait on busy session -> 204 after timeout, never 503
echo -n busy > "$MODE_FILE"
START=$(date +%s)
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -u opencode:test-secret-123 "$GW/api/session/ses_busy/wait")
[ "$CODE" = "204" ] || fail "expected 204 for busy wait timeout, got $CODE"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -ge 5 ] || fail "busy wait returned too fast (${ELAPSED}s); did it poll?"
[ "$ELAPSED" -lt 30 ] || fail "busy wait exceeded budget: ${ELAPSED}s"

# 6. chunked event stream passes through unbuffered
BODY=$(curl -fsS -u opencode:test-secret-123 "$GW/stream")
[ "$BODY" = 'helloworld' ] || fail "stream body mismatch: $BODY"

# 7. POST JSON body round-trips through the proxy untouched
GOT=$(curl -fsS -u opencode:test-secret-123 -X POST -H 'Content-Type: application/json' -d '{"location":{"directory":"/workspace/x"}}' "$GW/echo")
[ "$GOT" = '{"location":{"directory":"/workspace/x"}}' ] || fail "POST body mismatch: $GOT"

# 8. wait that settles mid-poll returns a fast 204
echo -n busy > "$MODE_FILE"
START=$(date +%s)
curl -fsS -o /dev/null -w '%{http_code}' -X POST -u opencode:test-secret-123 "$GW/api/session/ses_mid/wait" > "$T/mid.code" & MID_PID=$!
sleep 2
echo -n settled > "$MODE_FILE"
wait "$MID_PID" || fail "mid-wait curl failed"
CODE=$(cat "$T/mid.code")
[ "$CODE" = "204" ] || fail "expected 204 for mid-wait settle, got $CODE"
ELAPSED=$(( $(date +%s) - START ))
[ "$ELAPSED" -lt 8 ] || fail "mid-wait settle too slow: ${ELAPSED}s"

echo "opencode-gateway tests passed"
