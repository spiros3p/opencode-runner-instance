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

# Effective action for a read path, using V2 rule order: last match wins.
eff() { python3 - "$1" "$2" <<'PY'
import fnmatch, json, sys
cfg = json.load(open(sys.argv[1]))
action = "ask"
for rule in cfg.get("permissions", []):
    if rule.get("action") not in ("*", "read"):
        continue
    if fnmatch.fnmatch(sys.argv[2], rule.get("resource", "")):
        action = rule.get("effect", "ask")
print(action)
PY
}

# 1. missing file -> created with model + V2 permission defaults
mkdir -p "$T/a"
MODEL="acme/model" run "$T/a/opencode.json" >/dev/null
assert "model seeded" "$(jqget "$T/a/opencode.json" "d['model']")" "acme/model"
assert "v2 permissions list" "$(jqget "$T/a/opencode.json" "isinstance(d['permissions'], list)")" "True"
assert "env read effective" "$(eff "$T/a/opencode.json" ".env")" "deny"
assert "env example effective" "$(eff "$T/a/opencode.json" ".env.example")" "allow"
assert "normal read effective" "$(eff "$T/a/opencode.json" "main.py")" "allow"
assert "external allowed" "$(jqget "$T/a/opencode.json" "any(r['action']=='external_directory' and r['effect']=='allow' for r in d['permissions'])")" "True"

# 2. V1 permission object -> stripped, backed up, other keys kept
mkdir -p "$T/b"
cat > "$T/b/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "acme/model",
  "permission": {"read": {"*.env": "deny"}, "doom_loop": "deny"}
}
EOF
run "$T/b/opencode.json" >/dev/null
[ -f "$T/b/opencode.json.bak" ] || fail "v1 backup missing"
assert "v1 removed note" "$(jqget "$T/b/opencode.json" "'permission' in d")" "False"
assert "v1 key gone" "$(jqget "$T/b/opencode.json" "'permission' in d")" "False"
assert "model kept" "$(jqget "$T/b/opencode.json" "d['model']")" "acme/model"
assert "v2 defaults added" "$(eff "$T/b/opencode.json" ".env")" "deny"

# 3. nested V1 permission (agent block) -> stripped too
mkdir -p "$T/c"
cat > "$T/c/opencode.json" <<'EOF'
{
  "agent": { "build": { "permission": {"read": {"*": "ask"}} } },
  "provider": { "acme": { "options": { "apiKey": "keep-me" } } }
}
EOF
run "$T/c/opencode.json" >/dev/null
assert "nested v1 gone" "$(jqget "$T/c/opencode.json" "'permission' in d['agent']['build']")" "False"
assert "nested v2 written" "$(jqget "$T/c/opencode.json" "isinstance(d['agent']['build'].get('permissions'), list)")" "True"
assert "provider kept" "$(jqget "$T/c/opencode.json" "d['provider']['acme']['options']['apiKey']")" "keep-me"

# 4. JSONC with comments -> parsed, V2 permissions added, original backed up
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
assert "jsonc permissions added" "$(eff "$T/d/opencode.json" ".env")" "deny"

# 5. operator V2 rules win, and win by coming last (opencode takes last match)
mkdir -p "$T/e"
cat > "$T/e/opencode.json" <<'EOF'
{
  "permissions": [
    {"action": "read", "resource": "*.env", "effect": "allow"},
    {"action": "read", "resource": "secret.txt", "effect": "deny"},
    {"action": "shell", "resource": "*", "effect": "ask"}
  ]
}
EOF
run "$T/e/opencode.json" >/dev/null
assert "defaults prepended" "$(jqget "$T/e/opencode.json" "d['permissions'][0]['action']")" "*"
assert "operator env read effective" "$(eff "$T/e/opencode.json" ".env")" "allow"
assert "operator secret effective" "$(eff "$T/e/opencode.json" "secret.txt")" "deny"
assert "default env.local effective" "$(eff "$T/e/opencode.json" ".env.local")" "deny"
assert "operator rules come last" "$(jqget "$T/e/opencode.json" "d['permissions'][-1]['action']")" "shell"

# 6. invalid JSON -> backed up, fresh config
mkdir -p "$T/f"
printf 'not json at all' > "$T/f/opencode.json"
run "$T/f/opencode.json" >/dev/null 2>&1
[ -f "$T/f/opencode.json.invalid" ] || fail "invalid backup missing"
assert "fresh config valid" "$(jqget "$T/f/opencode.json" "isinstance(d['permissions'], list)")" "True"

# 7. binary junk -> no crash, config replaced
mkdir -p "$T/g"
printf '\x00\x01\x02binary' > "$T/g/opencode.json"
run "$T/g/opencode.json" >/dev/null 2>&1 || fail "binary config crashed the helper"
assert "binary replaced" "$(jqget "$T/g/opencode.json" "isinstance(d['permissions'], list)")" "True"

# 8. untouched when already good (V2 defaults present, no V1 keys)
mkdir -p "$T/h"
cat > "$T/h/opencode.json" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "acme/model",
  "permissions": [
    {"action": "*", "resource": "*", "effect": "allow"},
    {"action": "read", "resource": "*.env", "effect": "deny"},
    {"action": "read", "resource": "*.env.*", "effect": "deny"},
    {"action": "read", "resource": "*.env.example", "effect": "allow"},
    {"action": "external_directory", "resource": "*", "effect": "allow"}
  ]
}
EOF
BEFORE="$(cat "$T/h/opencode.json")"
run "$T/h/opencode.json" >/dev/null
assert "good config untouched" "$(cat "$T/h/opencode.json")" "$BEFORE"

# 9. wrong rule order on disk is repaired (defaults must come first)
mkdir -p "$T/i"
cat > "$T/i/opencode.json" <<'EOF'
{
  "permissions": [
    {"action": "read", "resource": "*.env", "effect": "deny"},
    {"action": "read", "resource": "*", "effect": "allow"}
  ]
}
EOF
assert "wrong order was unsafe" "$(eff "$T/i/opencode.json" ".env")" "allow"
run "$T/i/opencode.json" >/dev/null
assert "wrong order repaired" "$(eff "$T/i/opencode.json" ".env")" "deny"
assert "normal read still allowed" "$(eff "$T/i/opencode.json" "main.py")" "allow"

# 10. OPENCODE_MODEL env overrides a stale file value (redeploys switch default)
mkdir -p "$T/j"
echo '{"model": "stale/model"}' > "$T/j/opencode.json"
if [ -f "$T/j/opencode.json.bak" ]; then fail "backup exists before run"; fi
MODEL="fresh/model" run "$T/j/opencode.json" >/dev/null 2>"$T/j-err.txt"
[ -f "$T/j/opencode.json.bak" ] || fail "override backup missing"
assert "env model wins" "$(jqget "$T/j/opencode.json" "d['model']")" "fresh/model"
grep -q "overrides" "$T/j-err.txt" || fail "override note missing on stderr"

# 11. bare model (no provider prefix) still written, with a warning
mkdir -p "$T/k"
MODEL="baremodel" run "$T/k/opencode.json" >/dev/null 2>"$T/k-err.txt" || true
[ -f "$T/k/opencode.json" ] || fail "bare model config missing"
assert "bare model written" "$(jqget "$T/k/opencode.json" "d['model']")" "baremodel"
grep -q "no provider prefix" "$T/k-err.txt" || fail "bare model warning missing"

# 12. V2 provider apiKey wired to a PAT is stripped
mkdir -p "$T/l"
echo '{"model":"acme/model","providers":{"github-copilot":{"settings":{"apiKey":"{env:GITHUB_TOKEN}"}}}}' > "$T/l/opencode.json"
run "$T/l/opencode.json" >/dev/null 2>"$T/l-err.txt"
! grep -q '"apiKey"' "$T/l/opencode.json" || fail "V2 mapping not stripped"
grep -q "fetch-PAT" "$T/l-err.txt" || fail "sanitizer note missing"

# 13. V1 provider apiKey and GH_TOKEN are stripped too
mkdir -p "$T/m"
echo '{"model":"acme/model","provider":{"github-copilot":{"options":{"apiKey":"{env:GH_TOKEN}"}}}}' > "$T/m/opencode.json"
run "$T/m/opencode.json" >/dev/null 2>"$T/m-err.txt"
! grep -q '"apiKey"' "$T/m/opencode.json" || fail "V1/GH_TOKEN mapping not stripped"
grep -q "fetch-PAT" "$T/m-err.txt" || fail "sanitizer note missing"

# 14. a normal provider apiKey survives
mkdir -p "$T/n"
echo '{"model":"acme/model","providers":{"acme":{"settings":{"apiKey":"{env:ACME_KEY}"}}}}' > "$T/n/opencode.json"
run "$T/n/opencode.json" >/dev/null
assert "normal apiKey kept" "$(jqget "$T/n/opencode.json" "d['providers']['acme']['settings']['apiKey']")" "{env:ACME_KEY}"

# 15. malformed rule entries are dropped so V2 can still load the config
mkdir -p "$T/o"
echo '{"permissions":["oops", 7]}' > "$T/o/opencode.json"
run "$T/o/opencode.json" >/dev/null 2>"$T/o-err.txt"
! grep -q 'oops' "$T/o/opencode.json" || fail "malformed rule survived"
assert "defaults written after drop" "$(jqget "$T/o/opencode.json" "len(d['permissions'])")" "5"

# 16. operator rule order is preserved: a later broad deny still wins
mkdir -p "$T/p"
cat > "$T/p/opencode.json" <<'EOF'
{
  "permissions": [
    {"action": "read", "resource": "secret.txt", "effect": "allow"},
    {"action": "read", "resource": "*", "effect": "deny"}
  ]
}
EOF
run "$T/p/opencode.json" >/dev/null
assert "later deny wins" "$(eff "$T/p/opencode.json" "secret.txt")" "deny"
SPECIFIC="$(jqget "$T/p/opencode.json" "next(i for i,r in enumerate(d['permissions']) if r.get('resource')=='secret.txt')")"
BROAD="$(jqget "$T/p/opencode.json" "next(i for i,r in enumerate(d['permissions']) if r.get('action')=='read' and r.get('resource')=='*')")"
[ "$SPECIFIC" -lt "$BROAD" ] || fail "operator rule order was changed"

# 17. V1 bash deny is translated, not silently dropped
mkdir -p "$T/q"
echo '{"permission":{"bash":"deny","read":{"*.env":"deny"}}}' > "$T/q/opencode.json"
run "$T/q/opencode.json" >/dev/null 2>&1
assert "v1 shell deny kept" "$(jqget "$T/q/opencode.json" "any(r['action']=='shell' and r['effect']=='deny' for r in d['permissions'])")" "True"
assert "v1 key gone" "$(jqget "$T/q/opencode.json" "'permission' in d")" "False"

# 18. PAT in provider env list or as a raw token is stripped
mkdir -p "$T/r"
echo '{"providers":{"github-copilot":{"settings":{"env":["FETCH_GITHUB_TOKEN"]}},"x":{"settings":{"apiKey":"ghp_abc123"}}}}' > "$T/r/opencode.json"
run "$T/r/opencode.json" >/dev/null 2>&1
assert "PAT env stripped" "$(jqget "$T/r/opencode.json" "d['providers']['github-copilot']['settings']['env']")" "[]"
assert "raw token stripped" "$(jqget "$T/r/opencode.json" "'apiKey' in d['providers']['x']['settings']")" "False"

echo "opencode-config tests passed"
