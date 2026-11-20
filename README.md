# opencode-runner

Headless opencode agent on your tailnet. One container, one port plus an
optional browser VS Code (off by default), no second harness, no web-search
stack. Repos fetched on demand with a GitHub PAT and kept flat in `./workspace`.

| Port (default) | Service | Auth |
| -------------- | ------- | ---- |
| 4096 | native opencode HTTP server (`opencode serve`) | Basic: user `opencode`, password `OPENCODE_PASSWORD` |
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
# set GITHUB_TOKEN to a PAT with repo scope for the repos this runner may use
docker compose up -d --build
# optional UI: set ENABLE_CODE_SERVER=true in .env, then use:
# docker compose -f compose.yml -f compose.ui.yml up -d --build
docker logs opencode-runner 2>&1 | tail -20
curl -u opencode:"$OPENCODE_PASSWORD" http://127.0.0.1:4096/api/info
```

Tailscale is external. Publish ports on a tailnet host (or front them with
`tailscale serve`); do not expose 4096/8222 to the public internet.
UI access is full control of the runner: agent user has passwordless sudo,
so `CODE_SERVER_PASSWORD` protects provider keys and `GITHUB_TOKEN`.

## Fetch a repo

`fetch-repo` clones once into the flat `./workspace` layout. Repeat calls
return the same directory; no re-clone. It accepts `owner/repo` or an HTTPS
URL, plus an optional ref. github.com clones use `GITHUB_TOKEN` via askpass,
so the PAT never enters argv or `.git/config`. SSH URLs are rejected.

```bash
docker exec -u agent opencode-runner fetch-repo owner/repo main
# -> /workspace/repo
```

From a harness task, tell the agent to run `fetch-repo <owner/repo>` first and
work in the directory it prints. Same repo name from a different URL gets a
numeric suffix; nothing is nested under owner or platform directories.

## Harness calls

Tasks go through the native opencode server, not through this repo. Full
sequence in `docs/CALLING.md`; runnable script in `examples/call.sh`.

Short version:

```bash
# 1. session in the fetched directory
curl -fsS -X POST http://127.0.0.1:4096/api/session \
  -u "opencode:$OPENCODE_PASSWORD" -H 'Content-Type: application/json' \
  -d '{"location":{"directory":"/workspace/repo"},"title":"task"}'

# 2. prompt, wait, read assistant messages
#    POST /api/session/{id}/prompt
#    POST /api/experimental/session/{id}/wait
#    GET  /api/session/{id}/message?order=desc&limit=10
```

`@opencode/client` works too; see `docs/CALLING.md`.

Provider keys: set in `.env` or add at runtime through `/api/credential` and
`/api/integration/{id}/connect/key`. Config changes apply without restart.

## Delegate from another harness

Give this prompt to the remote harness agent. Replace `<runner-host>` and the
secret key name with your values:

```text
You are delegating work to a remote opencode runner. Set up delegation now.

Runner URL: http://<runner-host>:4096
Auth: HTTP Basic, user `opencode`. Read the password from your secret store
under `OPENCODE_RUNNER_PASSWORD`. Never print or echo it.
The runner holds its own GITHUB_TOKEN PAT. You do not send it.

For each delegated task:
1. Always run `fetch-repo <owner/repo> [ref]` first on the runner (it is cheap
   and idempotent). Create a session at /workspace and prompt the runner agent:
   "Run `fetch-repo <owner/repo> [ref]` and reply with the printed directory."
   Use that path as <dir>. There is no repo-listing API.
2. POST /api/session with {"location":{"directory":"<dir>"},"title":"<title>"}.
   Save the returned session id.
3. POST /api/session/{id}/prompt with the task text.
4. POST /api/experimental/session/{id}/wait.
5. GET /api/session/{id}/message?order=desc&limit=10 and
   GET /api/session/{id}/diff. Report the final assistant message and file
   diffs to me.

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

## Notes

- Default opencode policy allows tools; `.env` reads are denied so headless
  sessions never wait on an approval prompt for provider keys.
- `GITHUB_TOKEN` is a PAT in env, visible to the agent shell and to anything
  with sudo. Scope it to the repos this runner may work on and rotate it.
- Migrating from the old deploy key: delete `secrets/github_deploy_key` and
  remove that key from GitHub. `secrets/` stays gitignored.
- With `ENABLE_CODE_SERVER=true`, an unset `CODE_SERVER_PASSWORD` is generated
  per boot. Current password: `docker logs opencode-runner 2>&1 | grep 'code-server password' | tail -1`.
- `docker exec opencode-runner supervisorctl start code-server` only works when
  the flag is true; enable it in `.env` and recreate the container instead.
  The UI port is published only with the `compose.ui.yml` override.
- Seeds are once-only. Delete `$HOME/.config/opencode/opencode.json` to re-seed
  with a new `OPENCODE_MODEL`; this discards manual edits there.
- Permission crashes: entrypoint re-chowns home every boot. Live repair:
  `docker exec opencode-runner bash -c 'chown -R agent:agent /home/agent && chmod -R u+rwX,go-rwx /home/agent'`.
