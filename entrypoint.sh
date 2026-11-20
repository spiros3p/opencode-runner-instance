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
log "github pat: $([ -n "${GITHUB_TOKEN:-}" ] && echo set || echo unset)"

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

# Git identity. HTTPS clones use GITHUB_TOKEN via the fetch-repo askpass helper.
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

log "starting: opencode (:4096), code-server (:8443, $CODE_SERVER_ON)"
exec supervisord -c /etc/supervisor/supervisord.conf
