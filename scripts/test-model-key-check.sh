#!/usr/bin/env bash
# Hand-run tests for scripts/model-key-check. No network, no container.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }
assert() { [ "$2" = "$3" ] || fail "$1 (expected '$3', got '$2')"; }
run() { "$HERE/model-key-check" "$@"; }

[ -z "$(run)" ] || fail "empty model must print nothing"
[ -z "$(run "")" ] || fail "empty arg must print nothing"
assert "bare warns" "$(run baremodel)" "WARN: OPENCODE_MODEL has no provider prefix; use provider/id"
assert "copilot warns" "$(run github-copilot/x)" "WARN: default model github-copilot/x needs a Copilot OAuth token; a PAT fails with 400"
assert "unknown provider silent" "$(run wat/m 2>&1)" ""
assert "key set" "$(OPENCODE_API_KEY=sk-test-1 run opencode/m)" "default model: opencode/m (OPENCODE_API_KEY set)"
assert "key empty" "$(env -u OPENCODE_API_KEY "$HERE/model-key-check" opencode/m)" "WARN: default model opencode/m needs OPENCODE_API_KEY, which is empty"
assert "go shares key" "$(OPENCODE_API_KEY=sk-test-1 run opencode-go/deepseek-v4.1-flash)" "default model: opencode-go/deepseek-v4.1-flash (OPENCODE_API_KEY set)"

echo "model-key-check tests passed"
