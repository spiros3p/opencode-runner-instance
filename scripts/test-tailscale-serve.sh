#!/usr/bin/env bash
# Hand-run tests for scripts/tailscale-serve. Stubs docker, so no daemon
# and no network are needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Fake docker: records every call, answers inspect with $FAKE_RUNNING.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  inspect)
    [ "${FAKE_RUNNING:-true}" = "true" ] && echo true || echo false
    exit 0
    ;;
  exec)
    shift
    printf 'exec %s\n' "$*" >> "$FAKE_DOCKER_LOG"
    exit 0
    ;;
esac
exit 0
EOF
chmod 755 "$T/bin/docker"

fail() { echo "FAIL: $1" >&2; exit 1; }

export PATH="$T/bin:$PATH"
export FAKE_DOCKER_LOG="$T/log"
: > "$FAKE_DOCKER_LOG"

# 1. running container -> serve command with the exact flags
WAIT_TRIES=1 WAIT_SLEEP=0 "$HERE/tailscale-serve" >/dev/null
grep -q "exec tailscale tailscale serve --bg --https=8221 8221" "$FAKE_DOCKER_LOG" \
  || fail "serve command not issued: $(cat "$FAKE_DOCKER_LOG")"
grep -q "exec tailscale tailscale serve status" "$FAKE_DOCKER_LOG" \
  || fail "serve status not printed"

# 2. port and target are configurable
: > "$FAKE_DOCKER_LOG"
TAILSCALE_HTTPS_PORT=9443 SERVE_TARGET=http://opencode-runner:8443 WAIT_TRIES=1 WAIT_SLEEP=0 \
  "$HERE/tailscale-serve" >/dev/null
grep -q "exec tailscale tailscale serve --bg --https=9443 http://opencode-runner:8443" "$FAKE_DOCKER_LOG" \
  || fail "custom port/target not used: $(cat "$FAKE_DOCKER_LOG")"

# 3. container name is configurable
: > "$FAKE_DOCKER_LOG"
TAILSCALE_CONTAINER=ts-box WAIT_TRIES=1 WAIT_SLEEP=0 "$HERE/tailscale-serve" >/dev/null
grep -q "exec ts-box tailscale serve" "$FAKE_DOCKER_LOG" || fail "custom container not used"

# 4. tailscale container down -> fail loudly, no serve command
: > "$FAKE_DOCKER_LOG"
if FAKE_RUNNING=false WAIT_TRIES=2 WAIT_SLEEP=0 "$HERE/tailscale-serve" >/dev/null 2>"$T/err"; then
  fail "expected failure when the tailscale container is down"
fi
grep -q "not running" "$T/err" || fail "missing error message"
grep -q "serve --bg" "$FAKE_DOCKER_LOG" && fail "serve ran while container was down"

echo "tailscale-serve tests passed"
