#!/usr/bin/env bash
# One-shot example: run a task in an already-fetched repo, print last messages.
# Fetch with `docker exec -u agent opencode-runner fetch-repo owner/repo` first, or tell
# the runner agent to do it in the task prompt.
# Usage: OC=http://127.0.0.1:4096 OPENCODE_PASSWORD=... \
#        ./examples/call.sh /workspace/repo <task-prompt-file>
set -euo pipefail

OC="${OC:-http://127.0.0.1:4096}"
: "${OPENCODE_PASSWORD:?set OPENCODE_PASSWORD}"
DIR="${1:?usage: call.sh <runner-directory> <task-prompt-file>}"
TASK="${2:?usage: call.sh <runner-directory> <task-prompt-file>}"

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
