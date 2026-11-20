# Calling the runner from a harness

Two services, two auths. Commissioning uses the bearer token; agent work uses
the native opencode server.

## 1. Commission (once per repo)

```bash
curl -fsS -X POST http://RUNNER:8300/repos \
  -H "Authorization: Bearer $RUNNER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"url":"git@github.com:owner/repo.git","ref":"main"}'
```

Response: `{"id":"...","url":"...","name":"repo","directory":"/workspace/repo","created":true}`.

Repeating with the same URL returns `created:false` and the same directory.
Never re-clones. `GET /repos` lists all.

## 2. Run a task (native opencode API)

All calls use Basic auth: username `opencode`, password `OPENCODE_PASSWORD`.

```bash
BASE=http://RUNNER:4096
AUTH="opencode:$OPENCODE_PASSWORD"
DIR=/workspace/repo

SESSION=$(curl -fsS -X POST "$BASE/api/session" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"location\":{\"directory\":\"$DIR\"},\"title\":\"task\"}" | jq -r .id)

curl -fsS -X POST "$BASE/api/session/$SESSION/prompt" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Fix the failing login test and open a PR."}' >/dev/null

curl -fsS -X POST "$BASE/api/experimental/session/$SESSION/wait" -u "$AUTH" >/dev/null

curl -fsS "$BASE/api/session/$SESSION/message?order=desc&limit=10" -u "$AUTH" | jq '.data'
```

Useful endpoints:
- `POST /api/session` — create session at a location (`location.directory`).
- `POST /api/session/{id}/prompt` — admit one user message.
- `POST /api/session/{id}/interrupt` — stop an active run.
- `POST /api/experimental/session/{id}/wait` — block until idle.
- `GET /api/session/{id}/message` — read turn history.
- `GET /api/session/{id}/diff` — per-turn file diffs.
- `GET /api/project`, `GET /api/agent`, `GET /api/model/default` — discovery.
- `GET /openapi.json` — full contract on the running server.

## 3. JavaScript client

```ts
import { OpenCode } from "@opencode/client"

const client = OpenCode.make({
  baseUrl: "http://RUNNER:4096",
  headers: {
    authorization: `Basic ${Buffer.from(`opencode:${process.env.OPENCODE_PASSWORD}`).toString("base64")}`,
  },
})

const session = await client.session.create({
  location: { directory: "/workspace/repo" },
  title: "task",
})

await client.session.prompt({ sessionID: session.id, text: "Fix the failing login test." })
await client.session.wait({ sessionID: session.id })
```

For message reads, use `GET /api/session/{id}/message` (or the matching method
in the generated client — names mirror `/openapi.json` operation IDs).

## 4. Configure providers after boot

Provider keys can be added at runtime without a rebuild:

```bash
curl -fsS -X POST "$BASE/api/integration/anthropic/connect/key" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"key":"..."}'
```

Replace `anthropic` with the provider's integration ID. Check available IDs
with `GET /api/integration`.

Or set provider env vars in `.env` and rebuild. Never commit keys.

## Permissions

Default policy allows actions except reading `*.env` and `*.env.*` (denied).
If a caller adds an `ask` rule in the repo's own `opencode.json`, the harness
must answer permission requests through the API; headless runs will otherwise
stall. Keep runner config deny-based only.
