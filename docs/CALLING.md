# Calling the runner from a harness

One service, one auth. Agent work uses the native opencode server. Repos are
fetched on the runner by the `fetch-repo` helper, not over HTTP.

## 1. Fetch a repo (once per repo)

From the runner host:

```bash
docker exec -u agent opencode-runner fetch-repo owner/repo main
# -> /workspace/repo
```

From a harness, tell the runner agent in the first prompt to run
`fetch-repo <owner/repo> [ref]` and work in the directory it prints. The
helper clones once, returns the same path on repeat calls, and keeps all repos
flat under `/workspace`. github.com HTTPS clones use `FETCH_GITHUB_TOKEN` from the
runner's env; the caller does not send a token.

## 2. Run a task (native opencode API)

All calls use Basic auth: username `opencode`, password `OPENCODE_PASSWORD`.

```bash
BASE=http://RUNNER:4096
AUTH="opencode:$OPENCODE_PASSWORD"
DIR=/workspace/repo

SESSION=$(curl -fsS -X POST "$BASE/api/session" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"location\":{\"directory\":\"$DIR\"}}" | jq -r .data.id)

curl -fsS -X POST "$BASE/api/session/$SESSION/prompt" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "$(jq -nc --rawfile text "$TASK" '{prompt:{text:$text}}')" >/dev/null

curl -fsS -X POST "$BASE/api/session/$SESSION/wait" -u "$AUTH" >/dev/null

curl -fsS "$BASE/api/session/$SESSION/message?order=desc&limit=10" -u "$AUTH" | jq '.data'
```

Useful endpoints:
- `POST /api/session` — create session at a location (`location.directory`).
  Response is `{"data":{"id":"ses_..."}}`.
- `POST /api/session/{id}/prompt` — admit one user message. Body is
  `{"prompt":{"text":"..."}}`.
- `POST /api/session/{id}/interrupt` — stop an active run.
- `POST /api/session/{id}/model` — switch model mid-session. Body
  `{"model":{"providerID":"...","id":"...","variant?":"..."}}` (`variant`
  optional, e.g. `"high"` for reasoning effort; omit the key when unused).
- `POST /api/session/{id}/agent` — switch agent mid-session. Body
  `{"agent":"..."}` (e.g. `build` vs read-only `plan`).
- `GET /api/session/{id}/permission`, `GET /api/session/{id}/question` —
  list pending approval/question requests (`{"data":[...]}`). Answer with:
  - permission: `POST .../permission/{requestID}/reply` body
    `{"reply":"once"|"always"|"reject"}`
  - question: `POST .../question/{requestID}/reply` body
    `{"answers":[{"value":"..."}]}` (one entry per question, in order), or
    `POST .../question/{requestID}/reject` with no body.
  A headless caller polls these when a turn stalls instead of
  auto-answering. Exact shapes: `GET /doc`.
- `POST /api/session/{id}/wait` — block until the turn settles (gateway polls
  messages, then 204). Answers 204 on timeout too: always confirm via
  `GET .../message` until a `COMPLETE` assistant reply (`time.completed` or
  `finish` set; ignore streaming partials). Never loops forever client-side:
  use one overall deadline for wait + poll.
- `GET /api/session/{id}/message` — read turn history, `{"data":[...]}`.
- `GET /vcs/diff?directory=<dir>&mode=git` — working tree diff.
- `GET /api/agent`, `GET /api/model` — discovery.
- `GET /doc` — full API contract on the running server.

## 3. Choosing a model

The runner owns the provider keys, so the caller can only select models the
runner can serve.

```bash
# default: omit "model", the session uses the runner's configured model
curl -fsS -X POST "$BASE/api/session" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"location\":{\"directory\":\"$DIR\"}}"

# explicit model, on create or on a live session
curl -fsS -X POST "$BASE/api/session" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"location\":{\"directory\":\"$DIR\"},
       \"model\":{\"providerID\":\"opencode-go\",\"id\":\"deepseek-v4-pro\"}}"

curl -fsS -X POST "$BASE/api/session/$SESSION/model" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"model":{"providerID":"opencode-go","id":"deepseek-v4-pro"}}'

# what the runner can serve
curl -fsS "$BASE/api/model" -u "$AUTH"
```

Model ref is `{providerID, id, variant?}`. A provider with no key on the
runner is inactive and the turn fails with `Model unavailable: provider/model`.
Keys cannot be passed per call. Pass `variant` to select the reasoning
variant/effort the lane pins (e.g. `"high"`); omit the key when unused:

```bash
curl -fsS -X POST "$BASE/api/session/$SESSION/model" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"model":{"providerID":"opencode-go","id":"deepseek-v4.1-flash","variant":"high"}}'
```

## 4. JavaScript client

The V1 client shipped with opencode 1.19.6 (`createOpencodeClient`) talks to the
`/session` routes. Its `session.prompt` is synchronous, so there is no wait
call:

```ts
import { createOpencodeClient } from "@opencode/client"

const client = createOpencodeClient({
  baseUrl: "http://RUNNER:4096",
  headers: {
    authorization: `Basic ${Buffer.from(`opencode:${process.env.OPENCODE_PASSWORD}`).toString("base64")}`,
  },
})

const session = await client.session.create({
  query: { directory: "/workspace/repo" },
  body: { title: "task" },
})

await client.session.prompt({
  path: { id: session.data.id },
  body: { parts: [{ type: "text", text: "Fix the failing login test." }] },
})

const messages = await client.session.messages({ path: { id: session.data.id } })
```

For the `/api` routes used above, use the generated client that matches your
opencode version; method names mirror the `/doc` operation IDs.

## 5. Configure providers after boot

Provider keys can be added at runtime without a rebuild:

```bash
curl -fsS -X POST "$BASE/api/integration/anthropic/connect/key" -u "$AUTH" \
  -H 'Content-Type: application/json' \
  -d '{"key":"..."}'
```

Replace `anthropic` with the provider's integration ID. Check available IDs
with `GET /api/integration`.

Or set provider env vars in `.env` and recreate the container. The common
ones: `OPENCODE_API_KEY` (OpenCode Console and OpenCode Go),
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
`OPENROUTER_API_KEY`, `DEEPSEEK_API_KEY`. Pick the model with
`OPENCODE_MODEL=opencode-go/<model-id>` or `provider/model-id` in the task.

Never commit keys.

## Permissions

The runner writes a V1 `permission` block into
`/home/agent/.config/opencode/opencode.json` so a headless session never
blocks on an approval:

- `read` — `*.env` and `*.env.*` denied, `*.env.example` allowed
- `doom_loop` — denied, so a stuck loop errors instead of hanging
- `external_directory` — allowed, this is a dedicated runner

Operator rules in that file win over these defaults. A repo's own
`opencode.json` can add `ask` rules; a headless harness must then answer
through the permission API or the run stalls:

```bash
curl -fsS -X POST "$BASE/api/session/$SESSION/permission/$REQUEST_ID/reply" \
  -u "$AUTH" -H 'Content-Type: application/json' \
  -d '{"reply":"once"}'   # once | always | reject
```

Keep runner and repo configs deny-based.

## Review handoff

Reviews stay local. To review remote work: `GET .../message` for the final
assistant text, then the patch:

- `GET /vcs/diff?directory=<dir>&mode=git` — JSON array of
  `{file, patch, additions, deletions, status}`; the per-file `patch` field
  holds that file diff.
- `GET /vcs/diff/raw?directory=<dir>` — the whole diff as `text/x-diff`,
  ready for `git apply` (no `mode` parameter). Use this one to apply:
  `curl ... > patch.diff && git apply --check patch.diff`.

Apply to a local worktree, then run the normal local review lane. The runner
never merges.
