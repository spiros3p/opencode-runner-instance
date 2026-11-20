#!/usr/bin/env bash
# One-shot example: commission a repo, run a task, print the last messages.
# Usage: RUNNER=http://127.0.0.1:8300 OC=http://127.0.0.1:4096 \
#        RUNNER_API_TOKEN=... OPENCODE_PASSWORD=... \
#        ./examples/call.sh <git-url> <task-prompt-file>
set -euo pipefail

RUNNER="${RUNNER:-http://127.0.0.1:8300}"
OC="${OC:-http://127.0.0.1:4096}"
: "${RUNNER_API_TOKEN:?set RUNNER_API_TOKEN}"
: "${OPENCODE_PASSWORD:?set OPENCODE_PASSWORD}"
URL="${1:?usage: call.sh <git-url> <task-prompt-file>}"
TASK="${2:?usage: call.sh <git-url> <task-prompt-file>}"

REPO=$(curl -fsS -X POST "$RUNNER/repos" \
  -H "Authorization: Bearer $RUNNER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg url "$URL" '{url:$url}')")
DIR=$(printf '%s' "$REPO" | jq -r .directory)
echo "workspace: $DIR"

SESSION=$(curl -fsS -X POST "$OC/api/session" \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg d "$DIR" '{location:{directory:$d},title:"runner task"}')" | jq -r .id)
echo "session: $SESSION"

curl -fsS -X POST "$OC/api/session/$SESSION/prompt" \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d "$(jq -nc --rawfile text "$TASK" '{text:$text}')" >/dev/null

curl -fsS -X POST "$OC/api/experimental/session/$SESSION/wait" \
  -u "opencode:$OPENCODE_PASSWORD" >/dev/null

curl -fsS "$OC/api/session/$SESSION/message?order=desc&limit=10" \
  -u "opencode:$OPENCODE_PASSWORD" | jq '.data'
