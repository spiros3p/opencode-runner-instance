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
      "rev-parse --git-dir"*) [ -e "$DIR/.git" ] && printf '%s/.git\n' "$DIR" || exit 1 ;;
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
check "$C" "$T/ws/repo-$(printf '%s' 'github.com/other/repo' | cksum | cut -d' ' -f1)"
check "$(wc -l < "$T/count" | tr -d ' ')" "2"

# SSH-cloned checkout is reused, never re-cloned under a numeric suffix
mkdir -p "$T/ws/freb-app/.git"
printf '%s' 'git@github.com:owner/freb-app.git' > "$T/ws/freb-app/.git/origin"
CLONES_BEFORE="$(wc -l < "$T/count" | tr -d ' ')"
D="$(run owner/freb-app)"
check "$D" "$T/ws/freb-app"
[ "$(wc -l < "$T/count" | tr -d ' ')" = "$CLONES_BEFORE" ] || { echo "FAIL: ssh-origin repo was re-cloned" >&2; exit 1; }

# token-in-URL and http origins resolve to the same repo
mkdir -p "$T/ws/tok-app/.git"
printf '%s' 'https://x-access-token:sekret@github.com/owner/tok-app.git' > "$T/ws/tok-app/.git/origin"
check "$(run owner/tok-app)" "$T/ws/tok-app"
mkdir -p "$T/ws/http-app/.git"
printf '%s' 'http://github.com/owner/http-app' > "$T/ws/http-app/.git/origin"
check "$(run owner/http-app)" "$T/ws/http-app"
check "$(wc -l < "$T/count" | tr -d ' ')" "$CLONES_BEFORE"

# linked worktree (.git is a file, origin unreadable) counts as a repo.
# The stub pins rev-parse instead of validating the gitdir target like real
# git would, so the fixture target is created for consistency.
mkdir -p "$T/elsewhere/wt-app.git" "$T/ws/wt-app"
printf '%s' "gitdir: $T/elsewhere/wt-app.git" > "$T/ws/wt-app/.git"
check "$(run owner/wt-app)" "$T/ws/wt-app"

# genuinely different repo under the same name still takes the suffix
mkdir -p "$T/ws/clash/.git"
printf '%s' 'https://github.com/other/clash.git' > "$T/ws/clash/.git/origin"
check "$(run owner/clash)" "$T/ws/clash-$(printf '%s' 'github.com/owner/clash' | cksum | cut -d' ' -f1)"
check "$(wc -l < "$T/count" | tr -d ' ')" "3"

# pre-upgrade numeric-suffix dir (old https:// checksum) is reused, not cloned
OLD_SUM="$(printf '%s' 'https://github.com/owner/legacy' | cksum | cut -d' ' -f1)"
mkdir -p "$T/ws/legacy-$OLD_SUM/.git"
printf '%s' 'https://github.com/owner/legacy.git' > "$T/ws/legacy-$OLD_SUM/.git/origin"
check "$(run owner/legacy)" "$T/ws/legacy-$OLD_SUM"
check "$(wc -l < "$T/count" | tr -d ' ')" "3"

# scp-like SSH without a user still resolves to the same repo
mkdir -p "$T/ws/nouser/.git"
printf '%s' 'git.example.com:owner/nouser.git' > "$T/ws/nouser/.git/origin"
check "$(run https://git.example.com/owner/nouser)" "$T/ws/nouser"
check "$(wc -l < "$T/count" | tr -d ' ')" "3"

# bracketed IPv6 origin resolves to the same repo
mkdir -p "$T/ws/v6/.git"
printf '%s' 'ssh://git@[2001:db8::1]/owner/v6.git' > "$T/ws/v6/.git/origin"
check "$(run 'https://[2001:db8::1]/owner/v6')" "$T/ws/v6"
check "$(wc -l < "$T/count" | tr -d ' ')" "3"

if run git@github.com:owner/repo.git >/dev/null 2>&1; then echo "FAIL: SSH accepted" >&2; exit 1; fi
if run http://github.com/owner/repo >/dev/null 2>&1; then echo "FAIL: http accepted" >&2; exit 1; fi
echo "fetch-repo tests passed"
