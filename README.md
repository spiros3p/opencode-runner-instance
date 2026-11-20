# opencode-runner

Headless opencode agent on your tailnet. One container, two ports, no UI, no
second harness, no web-search stack. Generic: projects commissioned after boot.

| Port (default) | Service | Auth |
| -------------- | ------- | ---- |
| 4096 | native opencode HTTP server (`opencode serve`) | Basic: user `opencode`, password `OPENCODE_PASSWORD` |
| 8300 | repo commissioning service | Bearer `RUNNER_API_TOKEN` |

Two volumes:
- `opencode_runner_home` — opencode config, auth, sessions, repo registry.
- `./workspace` — one persistent checkout per commissioned repo.

## Quickstart

```bash
cp .env.example .env
# set OPENCODE_PASSWORD and RUNNER_API_TOKEN to long random values
mkdir -p secrets
ssh-keygen -t ed25519 -N "" -f secrets/github_deploy_key   # add .pub to GitHub/Forgejo
docker compose up -d --build
docker logs opencode-runner 2>&1 | tail -20
curl http://127.0.0.1:8300/healthz
curl -u opencode:"$OPENCODE_PASSWORD" http://127.0.0.1:4096/api/info
```

Tailscale is external. Publish ports on a tailnet host (or front them with
`tailscale serve`); do not expose 4096/8300 to the public internet.

## Commission a repo

Clone once, keep forever. Repeat call returns the same checkout; no re-clone.

```bash
curl -fsS -X POST http://127.0.0.1:8300/repos \
  -H "Authorization: Bearer $RUNNER_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"url":"git@github.com:owner/repo.git","ref":"main"}'
# -> {"id":"...","directory":"/workspace/repo","created":true}
```

`GET /repos` lists every checkout. URL accepts `git@host:path`, `ssh://`,
`https://`. `ref` optional (branch or tag). Directory derives from the URL;
name collisions get a short hash suffix.

## Harness calls

Tasks go through the native opencode server, not through this repo. Full
sequence in `docs/CALLING.md`; runnable script in `examples/call.sh`.

Short version:

```bash
# 1. session in the commissioned directory
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
- Deploy key is loaded into ssh-agent at boot. Private repos need the public
  key installed on the forge.
- Seeds are once-only. Delete `$HOME/.config/opencode/opencode.json` to re-seed
  with a new `OPENCODE_MODEL`; this discards manual edits there.
- Permission crashes: entrypoint re-chowns home every boot. Live repair:
  `docker exec opencode-runner bash -c 'chown -R agent:agent /home/agent && chmod -R u+rwX,go-rwx /home/agent'`.
