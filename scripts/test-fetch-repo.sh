#!/usr/bin/env bash
# Hand-run tests for fetch-repo. Stubs git so no network is needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/ws"

cat > "$T/bin/git" <<'EOF'
#!/usr/bin/env bash
COUNT="${FAKE_GIT_COUNT:?}"
case "$1" in
  clone)
    printf 'x\n' >> "$COUNT"
    TARGET="${@: -1}"
    URL="${@: -2:1}"
    mkdir -p "$TARGET/.git"
    printf '%s' "$URL" > "$TARGET/.git/origin"
    ;;
  -C)
    DIR="$2"
    case "$3 $4 $5" in
      "remote get-url origin") cat "$DIR/.git/origin" ;;
      "rev-parse --abbrev-ref HEAD") printf 'main\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$T/bin/git"
: > "$T/count"
export PATH="$T/bin:$PATH" FAKE_GIT_COUNT="$T/count" WORKSPACE="$T/ws"

run() { "$HERE/fetch-repo" "$@"; }
check() { [ "$1" = "$2" ] || { echo "FAIL: expected '$2', got '$1'" >&2; exit 1; }; }

A="$(run owner/repo.git)"
check "$A" "$T/ws/repo"
B="$(run https://github.com/owner/repo)"
check "$B" "$A"
check "$(wc -l < "$T/count" | tr -d ' ')" "1"

C="$(run https://github.com/other/repo)"
check "$C" "$T/ws/repo-$(printf '%s' 'https://github.com/other/repo' | cksum | cut -d' ' -f1)"
check "$(wc -l < "$T/count" | tr -d ' ')" "2"

if run git@github.com:owner/repo.git >/dev/null 2>&1; then echo "FAIL: SSH accepted" >&2; exit 1; fi
if run http://github.com/owner/repo >/dev/null 2>&1; then echo "FAIL: http accepted" >&2; exit 1; fi
echo "fetch-repo tests passed"
