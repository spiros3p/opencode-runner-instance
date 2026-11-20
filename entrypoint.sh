#!/bin/bash
# Headless opencode runner entrypoint: validate secrets, fix home volume, set up
# git/deploy key, seed opencode config once, start supervisord.
set -euo pipefail
H=/home/agent
log() { printf '[entrypoint] %s\n' "$*"; }

# No generated passwords. Both services need a stable secret known to the caller.
for v in OPENCODE_PASSWORD RUNNER_API_TOKEN; do
  val="${!v:-}"
  if [ -z "$val" ]; then
    echo "ERROR: $v is empty. Set it in .env." >&2
    exit 1
  fi
  case "$val" in
    change-me*|changeme*|REPLACE*)
      echo "ERROR: $v is still a placeholder. Set a long random value." >&2
      exit 1
      ;;
  esac
done
unset val

# Home lives on a named volume that shadows the baked image home.
mkdir -p /tmp/ssh-agent /run/supervisor /workspace
chown agent:agent /tmp/ssh-agent /run/supervisor /workspace
install -d -o agent -g agent -m 700 "$H"
[ -e "$H/.agentstack-init" ] || { cp -a /etc/skel/. "$H/"; touch "$H/.agentstack-init"; }

# Git push: deploy key -> ssh-agent; git identity.
if [ -f /run/secrets/github_deploy_key ]; then
  install -d -o agent -g agent -m 700 "$H/.ssh"
  install -m 600 -o agent -g agent /run/secrets/github_deploy_key "$H/.ssh/deploy_key"
  printf 'Host github.com ssh.github.com\n  IdentityFile ~/.ssh/deploy_key\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' > "$H/.ssh/config"
  chown agent:agent "$H/.ssh/config"
  chmod 600 "$H/.ssh/config"
  rm -f "$SSH_AUTH_SOCK"
  if runuser -u agent -- ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null 2>&1; then
    SSH_AUTH_SOCK="$SSH_AUTH_SOCK" runuser -u agent -- ssh-add "$H/.ssh/deploy_key" >/dev/null 2>&1 \
      && log "deploy key loaded into ssh-agent" \
      || log "WARN: ssh-add failed (passphrase-protected key?)"
  fi
else
  log "no deploy secret: agent can clone public repos only"
fi
git config --system --add safe.directory '*'
runuser -u agent -- env HOME="$H" git config --global user.name  "${GIT_IDENTITY_NAME:-Agent}"
runuser -u agent -- env HOME="$H" git config --global user.email "${GIT_IDENTITY_EMAIL:-agent@localhost}"

# Native opencode config. Seeded once, never overwrites edits. Default policy
# already allows actions except .env reads; deny those so headless tasks never
# hang on an approval prompt for provider keys.
install -d -o agent -g agent -m 700 "$H/.config/opencode" "$H/.config/opencode-runner"
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

log "starting: opencode (:4096), repo provisioner (:8300)"
exec supervisord -c /etc/supervisor/supervisord.conf
