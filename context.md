# context.md — brief for the orchestrator (dsh/brain)

You are making `scripts/remote-opencode-exec.sh` (in freb-workspace-orchestrator)
a first-class executor seat against the standalone opencode runner. The runner
repo is DONE and deployed; everything below is work in YOUR repo. Do not
touch the runner host, its `.env`, or its secrets.

## 1. What the runner is today

- Base URL `http://192.168.1.81:4096`, Basic auth user `opencode`, password
  from your secret store (`OPENCODE_RUNNER_PASSWORD` /
  `~/.config/freddo-buddy/opencode-runner.env`). Never print it.
  That file MUST be `0600` and owned by you; it was found `root:root 0644`
  (world-readable) and the owner still has to fix it. Assume it is exposed
  until you have verified `ls -l` yourself.
- Port 4096 is a gateway: it forwards everything to opencode and implements
  `POST /api/session/{id}/wait` (upstream leaves it a 503 stub). Wait
  answers **204 when the turn settles, 204 on timeout** — always poll
  messages afterwards.
- The runner holds its own fetch PAT (`FETCH_GITHUB_TOKEN`) for
  `fetch-repo`. Never send any `GITHUB_TOKEN`/`GH_TOKEN` of yours.
- No runner-wide default model (boot logs a warning instead). Every session
  MUST get an explicit model via `POST /api/session/{id}/model`.
- Provider keys live on the runner. Usable providers today: `opencode`,
  `opencode-go` (add `NVIDIA_API_KEY` there for `nvidia`).

## 2. Exact runner contract (do not deviate)

- `POST /api/session` body `{"location":{"directory":"<dir>"}}` — no
  title, no model. Session id is `data.id`.
- `POST /api/session/{id}/model` body
  `{"model":{"providerID":"...","id":"..."}}`, plus optional
  `"variant"` (e.g. `"high"` for reasoning effort; omit the key when
  unused). Set it after EVERY create; create never carries a model.
- `POST /api/session/{id}/agent` body `{"agent":"..."}` (`build` vs
  read-only `plan`). Same override pattern as model.
- `POST /api/session/{id}/prompt` body `{"text":"<task>"}` (V2; the V1
  `{"prompt":{"text":...}}` shape is rejected).
- `POST /api/session/{id}/wait` (body `{}`), then ALWAYS poll
  `GET /api/session/{id}/message?order=desc&limit=10` until a COMPLETE
  assistant reply: `finish` stop/completed (or `status` completed) with
  non-empty text. Streaming partials and tool-calls do not count.
  One overall deadline for wait+poll (600s); never loop forever.
- `GET /api/vcs/diff?location%5Bdirectory%5D=<dir>&mode=working` (brackets must
  stay percent-encoded or curl globbing breaks the call; V1 `/vcs/diff` and
  `/vcs/diff/raw` are gone).
- Stall diagnosis (no auto-approve, ever): `GET
  /api/session/{id}/permission` lists pending approvals (`{"data":[...]}`);
  answer with `POST .../permission/{id}/reply` body
  `{"decision":"once"|"always"|"reject"}`. V2 has no question API: questions
  arrive as forms via `GET /api/session/{id}/form` and
  `POST .../form/{id}/reply`. Keep prompts deny-based.
- Review handoff: runner never merges. Final text from `GET .../message`.
  Patch for applying: `GET /api/vcs/diff?location%5Bdirectory%5D=<dir>&mode=working`
  returns `{"location":...,"data":[...]}` with a `patch` field per file;
  concatenate those patches into a `git apply`-ready file. V1's raw-diff
  endpoint no longer exists. Apply locally, then review with the local lane.

## 3. Your work items (in order)

1. **Forward `--variant`.** Extend `model_body_of` to emit `variant` when
   set (`--variant` flag > `OPENCODE_RUNNER_VARIANT` > lane file value),
   omitting the key when empty. Fixtures: with/without variant (assert
   key ABSENT, not null). DoD: `test-remote-opencode-exec.sh` green.
2. **Lane context pack + agent call.** After create: `POST .../agent`
   with the lane file agent, and prepend a fixed header to the task text:
   agent behavior (build may edit/run/commit; plan is read-only, no shell),
   ticket id, task-class rules, no-commit rule. Derive from existing
   `--lane`; add no new flags. Fixtures: exact header text for build and
   plan; offline test for the agent call.
3. **Permission surfacing.** In the poll loop also GET permission/question
   lists; on any pending item stop polling and exit non-zero printing the
   session id + request ids. Fixtures: pending/empty for both. DoD: poll
   aborts with the session id instead of hanging to the deadline.
4. **Per-repo lock.** `flock -n` on a per-repo lock file (same name
   sanitization as the runner fetch helper) in `run`; fail fast when held.
   Offline test: second holder fails fast. Note: lock is host-local.
5. **Dispatch logging.** One TSV line per run/fetch in the existing
   `dispatch-log.tsv` column order, plus a per-session last-run record.
   Assert exact lines in tmp dirs.
6. **Review-handoff helper.** Subcommand that fetches final text + diff for
   a session id and prints the local apply-and-review commands. It must not
   apply or merge anything. Fixture: diff + messages, assert output bytes.

## 4. Hard rules

- Reviews stay local; only `build`/`build-fallback` go remote (keep the
existing exit-64 gates and the model allowlist).
- Never print the runner password; password travels only via curl stdin
  config, never argv. Never send any GitHub token to the runner.
- Keep every request/response shape above byte-identical; only ADD the
optional `variant` key and the new reads.
- Extend `test-remote-opencode-exec.sh` + fixtures for every item; the
  offline suite must stay green and must never touch the real runner.
- Sequencing: 1, then 2+3 together, then 4, 5, 6.

## 5. Acceptance (live, after your changes)

- `health` passes; `fetch` returns a `/workspace/<repo>` path.
- `run` with an explicit model + variant returns a COMPLETE assistant reply
  within the single deadline; `/api/vcs/diff` reflects the work.
- No 401/503 anywhere; a stalled permission surfaces the session id
  instead of hanging.

Runner details: `docs/CALLING.md`, `examples/call.sh`, `README.md`
(Troubleshooting) in the opencode-runner repo.
