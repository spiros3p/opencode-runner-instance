#!/usr/bin/env bash
# Hand-run tests for scripts/opencode-config. No network, no container.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

run() { OPENCODE_MODEL="${MODEL:-}" python3 "$HERE/opencode-config" "$1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
assert() { [ "$2" = "$3" ] || fail "$1 (expected '$3', got '$2')"; }
jqget() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d}))' "$1" "$2"; }

# Effective action for a read path, using opencode's rule order: last match wins.
# Read patterns match the path relative to the session directory.
eff() { python3 - "$1" "$2" <<'PY'
import fnmatch, json, sys
cfg = json.load(open(sys.argv[1]))
rules = cfg.get("permission", {}).get("read", {})
action = "ask"
for pattern, effect in rules.items():
    if fnmatch.fnmatch(sys.argv[2], pattern):
        action = effect
print(action)
PY
}

# 1. missing file -> created with model + permission defaults
mkdir -p "$T/a"
MODEL="acme/model" run "$T/a/opencode.json" >/dev/null
assert "model seeded" "$(jqget "$T/a/opencode.json" "d['model']")" "acme/model"
assert "env read denied" "$(jqget "$T/a/opencode.json" "d['permission']['read']['*.env']")" "deny"
assert "env read effective" "$(eff "$T/a/opencode.json" ".env")" "deny"
assert "doom_loop denied" "$(jqget "$T/a/opencode.json" "d['permission']['doom_loop']")" "deny"
assert "external allowed" "$(jqget "$T/a/opencode.json" "d['permission']['external_directory']")" "allow"

# 2. V2 seed -> stripped, backed up, other keys kept
mkdir -p "$T/b"
cat > "$T/b/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "acme/model",
  "permissions": [{"action": "read", "resource": "*.env", "effect": "deny"}]
}
EOF
run "$T/b/opencode.json" >/dev/null
[ -f "$T/b/opencode.json.v2.bak" ] || fail "v2 backup missing"
assert "v2 key gone" "$(jqget "$T/b/opencode.json" "'permissions' in d")" "False"
assert "model kept" "$(jqget "$T/b/opencode.json" "d['model']")" "acme/model"
assert "read rule added" "$(jqget "$T/b/opencode.json" "d['permission']['read']['*.env']")" "deny"

# 3. nested V2 permissions (agent block) -> stripped too
mkdir -p "$T/c"
cat > "$T/c/opencode.json" <<'EOF'
{
  "agent": { "build": { "permissions": [{"action": "shell", "resource": "*", "effect": "ask"}] } },
  "provider": { "acme": { "options": { "apiKey": "keep-me" } } }
}
EOF
run "$T/c/opencode.json" >/dev/null
assert "nested v2 gone" "$(jqget "$T/c/opencode.json" "'permissions' in d['agent']['build']")" "False"
assert "provider kept" "$(jqget "$T/c/opencode.json" "d['provider']['acme']['options']['apiKey']")" "keep-me"

# 4. JSONC with comments -> parsed, permission merged, original backed up
mkdir -p "$T/d"
cat > "$T/d/opencode.json" <<'EOF'
{
  // operator comment
  "$schema": "https://opencode.ai/config.json",
  "model": "acme/model",
}
EOF
run "$T/d/opencode.json" >/dev/null
[ -f "$T/d/opencode.json.bak" ] || fail "backup missing"
assert "jsonc model kept" "$(jqget "$T/d/opencode.json" "d['model']")" "acme/model"
assert "jsonc permission added" "$(jqget "$T/d/opencode.json" "d['permission']['read']['*.env']")" "deny"

# 5. operator rules win, and win by coming last (opencode takes last match)
mkdir -p "$T/e"
cat > "$T/e/opencode.json" <<'EOF'
{
  "permission": { "read": { "*.env": "allow", "secret.txt": "deny" }, "bash": "ask" }
}
EOF
run "$T/e/opencode.json" >/dev/null
assert "operator read kept" "$(jqget "$T/e/opencode.json" "d['permission']['read']['*.env']")" "allow"
assert "operator bash kept" "$(jqget "$T/e/opencode.json" "d['permission']['bash']")" "ask"
assert "doom_loop still added" "$(jqget "$T/e/opencode.json" "d['permission']['doom_loop']")" "deny"
assert "operator env read effective" "$(eff "$T/e/opencode.json" ".env")" "allow"
assert "operator secret effective" "$(eff "$T/e/opencode.json" "secret.txt")" "deny"
assert "default env read effective" "$(eff "$T/e/opencode.json" ".env.local")" "deny"
assert "default read allowed" "$(eff "$T/e/opencode.json" "main.py")" "allow"
assert "operator rules come last" "$(jqget "$T/e/opencode.json" "list(d['permission']['read'])[-1]")" "secret.txt"

# 6. invalid JSON -> backed up, fresh config
mkdir -p "$T/f"
printf 'not json at all' > "$T/f/opencode.json"
run "$T/f/opencode.json" >/dev/null 2>&1
[ -f "$T/f/opencode.json.invalid" ] || fail "invalid backup missing"
assert "fresh config valid" "$(jqget "$T/f/opencode.json" "d['permission']['doom_loop']")" "deny"

# 7. binary junk -> no crash, config replaced
mkdir -p "$T/g"
printf '\x00\x01\x02binary' > "$T/g/opencode.json"
run "$T/g/opencode.json" >/dev/null 2>&1 || fail "binary config crashed the helper"
assert "binary replaced" "$(jqget "$T/g/opencode.json" "d['permission']['doom_loop']")" "deny"

# 8. untouched when already good
mkdir -p "$T/h"
cat > "$T/h/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "acme/model",
  "permission": {
    "read": { "*": "allow", "*.env": "deny", "*.env.*": "deny", "*.env.example": "allow" },
    "doom_loop": "deny",
    "external_directory": "allow"
  }
}
EOF
BEFORE="$(cat "$T/h/opencode.json")"
run "$T/h/opencode.json" >/dev/null
assert "good config untouched" "$(cat "$T/h/opencode.json")" "$BEFORE"

# 9. wrong rule order on disk is repaired (defaults must come first)
mkdir -p "$T/i"
cat > "$T/i/opencode.json" <<'EOF'
{
  "permission": { "read": { "*.env": "deny", "*": "allow" } }
}
EOF
assert "wrong order was unsafe" "$(eff "$T/i/opencode.json" ".env")" "allow"
run "$T/i/opencode.json" >/dev/null
assert "wrong order repaired" "$(eff "$T/i/opencode.json" ".env")" "deny"
assert "normal read still allowed" "$(eff "$T/i/opencode.json" "main.py")" "allow"

echo "opencode-config tests passed"
