# opencode-runner

Headless opencode agent on your tailnet. One container, one port plus an
optional browser VS Code (off by default), no second harness, no web-search
stack. Repos fetched on demand with a GitHub PAT and kept flat in `./workspace`.

| Port (default) | Service | Auth |
| -------------- | ------- | ---- |
| 4096 | gateway (`scripts/opencode-gateway`): forwards to opencode on loopback, implements `POST /api/session/{id}/wait` | Basic: user `opencode`, password `OPENCODE_PASSWORD` |
| 8222 host → 8443 container | optional VS Code (`code-server`) | Password `CODE_SERVER_PASSWORD` |

Code-server is off by default. To run it: set `ENABLE_CODE_SERVER=true` in
`.env` and add the `compose.ui.yml` override so host port 8222 is published.
The override is separate so a busy host port cannot block the headless runner.

Two volumes:
- `opencode_runner_home` — opencode config, auth, sessions.
- `./workspace` — one flat persistent checkout per repo, named after the repo.

## Quickstart

```bash
cp .env.example .env
# set OPENCODE_PASSWORD to a long random value
# set FETCH_GITHUB_TOKEN to a PAT with repo scope for the repos this runner may use
docker compose up -d --build
# optional UI: set ENABLE_CODE_SERVER=true in .env, then use:
# docker compose -f compose.yml -f compose.ui.yml up -d --build
docker logs opencode-runner 2>&1 | tail -20
curl -u opencode:"$OPENCODE_PASSWORD" http://127.0.0.1:4096/api/health
```

Tailscale is external. Publish ports on a tailnet host (or front them with
`tailscale serve`); do not expose 4096/8222 to the public internet.
UI access is full control of the runner: agent user has passwordless sudo,
so `CODE_SERVER_PASSWORD` protects provider keys and `FETCH_GITHUB_TOKEN`.

## Fetch a repo

`fetch-repo` clones once into the flat `./workspace` layout. Repeat calls
return the same directory; no re-clone. It accepts `owner/repo` or an HTTPS
URL, plus an optional ref. github.com clones use `FETCH_GITHUB_TOKEN` via askpass,
so the PAT never enters argv or `.git/config`. SSH URLs are rejected.

```bash
docker exec -u agent opencode-runner fetch-repo owner/repo main
# -> /workspace/repo
```

From a harness task, tell the agent to run `fetch-repo <owner/repo>` first and
work in the directory it prints. An existing checkout is reused when its
origin is the same repo, however it was cloned (https, ssh, or token URL).
Only a genuinely different repo under the same name gets a numeric suffix;
nothing is nested under owner or platform directories.

## Harness calls

Tasks go through the native opencode server, not through this repo. Full
sequence in `docs/CALLING.md`; runnable script in `examples/call.sh`.

Short version:

```bash
# 1. session in the fetched directory (response: {"data":{"id":"ses_..."}})
curl -fsS -X POST http://127.0.0.1:4096/api/session \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"location":{"directory":"/workspace/repo"}}'

# 2. prompt, wait, read assistant messages
#    POST /api/session/{id}/prompt      body: {"prompt":{"text":"..."}}
#    POST /api/session/{id}/wait        gateway blocks until the turn settles,
#                                       then 204 (or 204 on timeout: poll below)
#    GET  /api/session/{id}/message?order=desc&limit=10   -> {"data":[...]}
#    GET  /vcs/diff?directory=/workspace/repo&mode=git
```

Upstream `opencode serve` 1.x leaves `POST /api/session/{id}/wait` as a stub
that always answers 503. The gateway on port 4096 implements it: it polls
the session messages until the newest message is a finished assistant turn
and answers 204, so the client then reads the reply. If the budget
(`WAIT_TIMEOUT_SECONDS`, default 600) runs out it still answers 204 and the
client polls `GET .../message` until a `COMPLETE` assistant reply appears
(`time.completed` set, or `finish` set; streaming partials do not count).

`@opencode/client` works too; see `docs/CALLING.md`.

### Choosing a model

The caller may pick the model per session, but the runner holds the provider
keys, so only models the runner can serve are usable:

```bash
# omit "model" -> the runner's configured default (OPENCODE_MODEL)
curl -fsS -X POST http://127.0.0.1:4096/api/session \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"location":{"directory":"/workspace/repo"}}'

# explicit model
curl -fsS -X POST http://127.0.0.1:4096/api/session \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"location":{"directory":"/workspace/repo"},
       "model":{"providerID":"opencode-go","id":"deepseek-v4-pro"}}'

# switch model on a live session
curl -fsS -X POST http://127.0.0.1:4096/api/session/$SESSION/model \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"model":{"providerID":"opencode-go","id":"deepseek-v4-pro"}}'

# what the runner can actually serve
curl -fsS http://127.0.0.1:4096/api/model -u "opencode:$OPENCODE_PASSWORD"
```

A model whose provider has no key on the runner fails with
`Model unavailable: provider/model`. The caller cannot pass a key at call
time.

## Provider credentials

The runner passes `.env` straight into the opencode server process, so any
provider env var opencode knows works. The env var name comes from the
provider catalog (models.dev):

| Provider id | Env var | Notes |
| ----------- | ------- | ----- |
| `opencode` | `OPENCODE_API_KEY` | OpenCode Console, pay per token |
| `opencode-go` | `OPENCODE_API_KEY` | OpenCode Go subscription |
| `anthropic` | `ANTHROPIC_API_KEY` | |
| `openai` | `OPENAI_API_KEY` | |
| `google` | `GEMINI_API_KEY` | |
| `openrouter` | `OPENROUTER_API_KEY` | |
| `deepseek` | `DEEPSEEK_API_KEY` | |
| `nvidia` | `NVIDIA_API_KEY` | fallback seat models (e.g. `minimaxai/minimax-m3.1-flash`) |
| `github-copilot` | OAuth token in `auth.json` only | `opencode providers` login; the fetch PAT is rejected by the Copilot API (HTTP 400) |

The provider/key mapping above is mirrored in `scripts/model-key-check`
(the boot check); update both together.

`GITHUB_TOKEN` must never be set on this runner: the models.dev catalog maps
that name to the `github-copilot` provider, so a fetch PAT there breaks every
copilot turn. The fetch PAT is therefore `FETCH_GITHUB_TOKEN`, and boot fails
fast if the legacy `GITHUB_TOKEN` name is still present.

One key in `.env`:

```bash
OPENCODE_API_KEY=sk-...
OPENCODE_MODEL=opencode-go/deepseek-v4-pro
```

`OPENCODE_API_KEY` is shared by `opencode` and `opencode-go`, so one env var
covers one of them at a time. For two keys at once, put them in the config
instead and reference them with `{env:VAR}`:

```jsonc
// /home/agent/.config/opencode/opencode.json
{
  "model": "opencode-go/deepseek-v4-pro",
  "provider": {
    "opencode-go": { "options": { "apiKey": "{env:OPENCODE_GO_KEY}" } },
    "opencode": { "options": { "apiKey": "{env:OPENCODE_CONSOLE_KEY}" } }
  }
}
```

Then add both vars to `.env`. The key never lands in the file itself.

Apply and verify:

```bash
docker compose up -d --force-recreate      # env_file changes need a recreate
docker exec -u agent opencode-runner opencode models opencode-go | head
```

`opencode models <provider>` lists what the runner can actually reach. The
first prompt after adding a key fails if the model id is wrong.

Keys can also be stored by opencode itself in
`/home/agent/.local/share/opencode/auth.json` (inside the home volume) via
`opencode providers`, or at runtime with
`POST /api/integration/{providerID}/connect/key` body `{"key":"..."}`. Env is
the simple path; the stored path keeps the key out of the container env.

Provider keys are visible to the agent shell (`env`) and to anything with
sudo. Scope and rotate them like the GitHub PAT.

## Delegate from another harness

Give this prompt to the remote harness agent. Replace `<runner-host>` and the
secret key name with your values:

```text
You are delegating work to a remote opencode runner. Set up delegation now.

Runner URL: http://<runner-host>:4096
Auth: HTTP Basic, user `opencode`. Read the password from your secret store
under `OPENCODE_RUNNER_PASSWORD`. Never print or echo it.
The runner holds its own FETCH_GITHUB_TOKEN PAT. You do not send it.

For each delegated task:
1. Always run `fetch-repo <owner/repo> [ref]` first on the runner (it is cheap
   and idempotent). Create a session at /workspace and prompt the runner agent:
   "Run `fetch-repo <owner/repo> [ref]` and reply with the printed directory."
   Use that path as <dir>. There is no repo-listing API.
2. POST /api/session with {"location":{"directory":"<dir>"}}. Read the session
   id from the response field data.id. Do not send a "model" field: the runner
   uses its own configured default. If a task needs a specific model, first
   GET /api/model and use one the runner lists there, then
   POST /api/session/{id}/model with {"model":{"providerID":"...","id":"..."}}.
3. POST /api/session/{id}/prompt with body {"prompt":{"text":"<task>"}}.
4. POST /api/session/{id}/wait.
5. GET /api/session/{id}/message?order=desc&limit=10 and
   GET /vcs/diff?directory=<dir>&mode=git. Report the final assistant message
   and the diff to me.

All repos stay flat under /workspace. Do not clone locally. Do not ask the
runner for its PAT. Do not commit or push unless the task says so.
```

## Update opencode

Version pinned in `Dockerfile` (`ARG OPENCODE_VERSION=1.19.6`). Bump it, then:

```bash
docker compose up -d --build
docker exec opencode-runner opencode --version
```

Plain `docker compose up -d` reuses the old image. Rebuild required.

## Troubleshooting

All commands run on the runner host, never from the calling harness.

- `POST .../wait` returns 503: you are hitting an image without the gateway.
  Rebuild and recreate (`docker compose up -d --build --force-recreate`).
  The gateway answers 204 (settled) or 204 on timeout (poll messages).
- Prompt admitted but no assistant message appears within minutes: the
  provider call never returned. Check `docker logs opencode-runner` for the
  boot line `default model: ...` (warns when the provider key env var is
  empty), verify the key, then from the host:
  `docker exec -u agent opencode-runner opencode models <provider> | head`
  and `curl -m 10 -o /dev/null -w "%{http_code}" https://opencode.ai/inference/openai/v1/models`.
  Free-tier models can also queue server-side for a long time; a cheap paid
  model is the better default.
- `github-copilot` turn errors `Personal Access Tokens are not supported`:
  a PAT reached the provider. Boot fails while legacy `GITHUB_TOKEN` is set;
  after the rename, `GITHUB_TOKEN` must stay unset so the catalog default
  cannot pick it up. Copilot needs an OAuth token via `opencode providers`.
- `Model unavailable: provider/model`: the model id is wrong or its provider
  has no key. List `GET /api/model` and match the provider to the key table.

## Notes

- `OPENCODE_PASSWORD` is exported to the server as `OPENCODE_SERVER_PASSWORD`
  at boot; the Basic auth username defaults to `opencode`
  (`OPENCODE_SERVER_USERNAME`).
- `FETCH_GITHUB_TOKEN` is a PAT in env, visible to the agent shell and to anything
  with sudo. Scope it to the repos this runner may work on and rotate it.
- Migrating from the old deploy key: delete `secrets/github_deploy_key` and
  remove that key from GitHub. `secrets/` stays gitignored.
- With `ENABLE_CODE_SERVER=true`, an unset `CODE_SERVER_PASSWORD` is generated
  per boot. Current password: `docker logs opencode-runner 2>&1 | grep 'code-server password' | tail -1`.
- `docker exec opencode-runner supervisorctl start code-server` only works when
  the flag is true; enable it in `.env` and recreate the container instead.
  The UI port is published only with the `compose.ui.yml` override.
- `opencode.json` is written at boot by `scripts/opencode-config`: it holds
  `$schema`, the model, and the V1 `permission` block. A V2 `permissions` array
  from an older image is removed (original kept as `opencode.json.v2.bak`), an
  unparseable file is kept as `opencode.json.invalid`, and every other key you
  added is preserved.
- Model selection: leave `OPENCODE_MODEL` empty (recommended). The delegating
  agent then sets the model per session and the runner keeps no default;
  boot logs a reminder. Set `OPENCODE_MODEL=provider/id` in `.env` and
  recreate only to pin a runner-wide default: the env value always wins
  over the `model` key stored in `opencode.json` (the helper logs the
  override and backs the file up). A bare id without a `provider/` prefix
  warns at boot and rarely resolves.
- Permission crashes: entrypoint re-chowns home every boot. Live repair:
  `docker exec opencode-runner bash -c 'chown -R agent:agent /home/agent && chmod -R u+rwX,go-rwx /home/agent'`.
- Tests: `scripts/test-fetch-repo.sh`, `scripts/test-opencode-config.sh`,
  `scripts/test-opencode-gateway.sh`, and `scripts/test-model-key-check.sh`
  run locally with no network and no container.
- Migrating `GITHUB_TOKEN` -> `FETCH_GITHUB_TOKEN`: rename the var in `.env`
  and recreate. Boot refuses to start while the legacy name is set, because
  the catalog would hand the PAT to the github-copilot provider.
