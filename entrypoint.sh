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
unset OP_PASSWORD
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

# Native opencode config. Seeded once, never overwrites edits. Default policy
# already allows actions except .env reads; deny those so headless tasks never
# hang on an approval prompt for provider keys.
install -d -o agent -g agent -m 700 "$H/.config/opencode"
if [ ! -f "$H/.config/opencode/opencode.json" ]; then
  if [ -n "${OPENCODE_MODEL:-}" ]; then
    cat > "$H/.config/opencode/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$OPENCODE_MODEL",
  "permissions": [
    { "action": "read", "resource": "*.env", "effect": "deny" },
    { "action": "read", "resource": "*.env.*", "effect": "deny" },
    { "action": "read", "resource": "*.env.example", "effect": "allow" }
  ]
}
EOF
  else
    cat > "$H/.config/opencode/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "permissions": [
    { "action": "read", "resource": "*.env", "effect": "deny" },
    { "action": "read", "resource": "*.env.*", "effect": "deny" },
    { "action": "read", "resource": "*.env.example", "effect": "allow" }
  ]
}
EOF
  fi
  log "seeded $H/.config/opencode/opencode.json (delete it to re-seed)"
fi

# Owner-only everywhere. Kills EACCES crash loops and satisfies secret checks.
chown -R agent:agent "$H"
chmod -R u+rwX,go-rwx "$H"

log "starting: opencode (:4096), code-server (:8443, $CODE_SERVER_ON)"
exec supervisord -c /etc/supervisor/supervisord.conf
