#!/bin/bash
# Headless opencode runner entrypoint: validate secret, fix home volume, seed
# opencode config once, start supervisord.
set -euo pipefail
H=/home/agent
log() { printf '[entrypoint] %s\n' "$*"; }

# No generated password. Callers need a stable opencode password.
OP_PASSWORD="${OPENCODE_PASSWORD:-}"
[ -n "$OP_PASSWORD" ] || { echo "ERROR: OPENCODE_PASSWORD is empty. Set it in .env." >&2; exit 1; }
case "$OP_PASSWORD" in
  change-me*|changeme*|REPLACE*)
    echo "ERROR: OPENCODE_PASSWORD is still a placeholder. Set a long random value." >&2
    exit 1
    ;;
esac
# opencode's native server reads these names. Keep OPENCODE_PASSWORD as the
# .env-facing name and map it, so callers use the documented variable.
export OPENCODE_SERVER_PASSWORD="${OPENCODE_SERVER_PASSWORD:-$OP_PASSWORD}"
export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
unset OP_PASSWORD
log "opencode auth: user $OPENCODE_SERVER_USERNAME, password set"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN is set. Rename it to FETCH_GITHUB_TOKEN in .env:" >&2
  echo "the models.dev catalog maps GITHUB_TOKEN to the github-copilot provider," >&2
  echo "and the Copilot API rejects PATs, so every copilot turn would fail." >&2
  exit 1
fi
unset GITHUB_TOKEN
# gh reads GH_TOKEN. models.dev maps only GITHUB_TOKEN (to github-copilot), so
# exposing the fetch PAT under GH_TOKEN lets gh authenticate without reviving
# the name that breaks copilot. compose.yml also sets GH_TOKEN in the container
# config, because `docker exec` inherits that, not the exports made here.
if [ -n "${FETCH_GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GH_TOKEN:-$FETCH_GITHUB_TOKEN}"
fi
log "fetch pat: $([ -n "${FETCH_GITHUB_TOKEN:-}" ] && echo set || echo unset) (FETCH_GITHUB_TOKEN: fetch-repo clones only, hidden from the model server)"

# Default-model provider check. The runner answers only when the default
# model's provider has a key. Warns here so a missing key is visible in
# `docker logs` instead of surfacing as a silent stuck turn. The logic lives
# in scripts/model-key-check (unit-tested); the entrypoint relays its line.
MODEL_CHECK_OUT="$(/usr/local/bin/model-key-check "${OPENCODE_MODEL:-}")"
if [ -n "$MODEL_CHECK_OUT" ]; then log "$MODEL_CHECK_OUT"; fi

# code-server is opt-in. Normalize once so supervisord always gets true/false;
# mixed case and trailing whitespace in .env must not silently disable it.
CS_FLAG="$(printf '%s' "${ENABLE_CODE_SERVER:-false}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
case "$CS_FLAG" in
  true|1|yes|on) CS_FLAG=true ;;
  *) CS_FLAG=false ;;
esac
export ENABLE_CODE_SERVER="$CS_FLAG"
CODE_SERVER_ON="$CS_FLAG"
log "code-server: $CODE_SERVER_ON"

# Password pinned in .env, else random per boot (printed once, current = last).
if [ "$CODE_SERVER_ON" = true ]; then
  if [ -n "${CODE_SERVER_PASSWORD:-}" ]; then
    log "code-server password: (pinned in .env)"
  else
    export CODE_SERVER_PASSWORD="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    log "code-server password: $CODE_SERVER_PASSWORD"
  fi
fi

# Home lives on a named volume that shadows the baked image home.
mkdir -p /run/supervisor /workspace
chown agent:agent /run/supervisor /workspace
install -d -o agent -g agent -m 700 "$H"
[ -e "$H/.agentstack-init" ] || { cp -a /etc/skel/. "$H/"; touch "$H/.agentstack-init"; }

# Git identity. HTTPS clones use FETCH_GITHUB_TOKEN via the fetch-repo askpass helper.
git config --system --add safe.directory '*'
runuser -u agent -- env HOME="$H" git config --global user.name  "${GIT_IDENTITY_NAME:-Agent}"
runuser -u agent -- env HOME="$H" git config --global user.email "${GIT_IDENTITY_EMAIL:-agent@localhost}"

# Owner-only everywhere. Kills EACCES crash loops and satisfies secret checks.
# Runs before the config helper so a root-owned config is still readable.
chown -R agent:agent "$H"
chmod -R u+rwX,go-rwx "$H"

# Native opencode config. The image pins opencode 1.x, which rejects the V2
# `permissions` array and then refuses to start. The helper repairs that,
# keeps the operator's own keys, and adds the V1 permission defaults that stop
# a headless session from blocking on an approval prompt.
install -d -o agent -g agent -m 700 "$H/.config/opencode"
OC_CFG="$H/.config/opencode/opencode.json"
if ! OC_OUT="$(runuser -u agent -- env HOME="$H" OPENCODE_MODEL="${OPENCODE_MODEL:-}" \
  /usr/bin/python3 /usr/local/bin/opencode-config "$OC_CFG" 2>&1)"; then
  log "WARN: opencode config helper failed: $OC_OUT"
else
  [ -n "$OC_OUT" ] && log "opencode config: $OC_OUT"
fi

chown -R agent:agent "$H"
chmod -R u+rwX,go-rwx "$H"

export GATEWAY_UPSTREAM_HOST="${GATEWAY_UPSTREAM_HOST:-127.0.0.1}"
export GATEWAY_UPSTREAM_PORT="${GATEWAY_UPSTREAM_PORT:-4097}"
export WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-540}"
export WAIT_POLL_SECONDS="${WAIT_POLL_SECONDS:-1.5}"
log "gateway: :4096 -> $GATEWAY_UPSTREAM_HOST:$GATEWAY_UPSTREAM_PORT (wait timeout ${WAIT_TIMEOUT_SECONDS}s)"
log "starting: gateway (:4096), opencode (:4097 loopback), code-server (:8443, $CODE_SERVER_ON)"
exec supervisord -c /etc/supervisor/supervisord.conf
