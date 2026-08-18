# Task I-1: Infrastructure Validation Report

## Status
Milestone 1 Integration Sprint, Task I-1. Validation only — no workflow
logic or feature changes made.

## Scope

Verify the local dev environment can execute the full pipeline
(01-ingestion through 07-jira-agent). Checked: Docker services, n8n
instance, PostgreSQL, Ollama, installed model, mounted project folders,
environment variables, n8n credentials, workflow imports, workflow
activation.

## Method

`docker ps`, `docker inspect`, `docker exec` into the running containers,
`n8n list:workflow` / `export:credentials` via the n8n CLI inside the
container, direct `psql` queries against the running Postgres, `ollama
list` on the host, and a JSON-parse pass over every file in
`n8n/workflows/`.

---

## Environment Checklist

| # | Item | Status | Detail |
|---|---|---|---|
| 1 | Docker Engine / Compose installed | ✅ PASS | Docker 29.5.3, Compose v5.1.4 |
| 2 | `n8n` container running | ✅ PASS | `qa-test-agent-n8n-1`, up 39 min, port 5678, `/healthz` → 200 |
| 3 | `postgres` container running | ✅ PASS | `qa-test-agent-postgres-1`, up 39 min, port 5432 open |
| 4 | Postgres schema matches `db/init/001_init_schema.sql` | ✅ PASS | `runs`, `decisions`, `jira_tickets` present with matching columns/constraints; all 3 tables empty (0 rows) — no data at risk |
| 5 | Ollama installed on host | ✅ PASS | `ollama version 0.32.6` |
| 6 | Required model available | ✅ PASS | `llama3:latest` (4.7 GB) pulled |
| 7 | `.env` present in repo | ❌ **BLOCKER** | Only `.env.example` exists in `QA-Engineer/`; no real `.env` anywhere on disk (see Issue 1) |
| 8 | Bind-mounted project folders (`reports/`, `test-scripts/`) | ❌ **BLOCKER** | Container mounts resolve to a stale path, not this repo (see Issue 2) |
| 9 | n8n credentials configured | ❌ **BLOCKER** (for later stages) | `export:credentials --all` → "No credentials found" — no Anthropic/Jira/HTTP-auth credentials exist in this n8n instance |
| 10 | Workflows 01–07 imported into n8n | ❌ **BLOCKER** | `n8n list:workflow` shows only the default `"My workflow"` placeholder; none of the 8 committed workflow files have ever been imported |
| 11 | Workflows activated | ❌ **BLOCKER** (follows from #10) | n8n startup log: "Processed 0 draft workflows, 0 published workflows" |
| 12 | Workflow JSON structurally valid | ✅ PASS | All 8 files (`01`–`07`, incl. `06.1`) parse as valid JSON |
| 13 | Node types used are core n8n nodes (no missing community nodes) | ✅ PASS | Only `code`, `httpRequest`, `if`, `filter`, `noOp`, `readWriteFile`, `spreadsheetFile`, `localFileTrigger`, `executeWorkflowTrigger`, `stickyNote` — all ship with n8n 2.32.5 |

---

## Blocking Issues

### Issue 1 — No `.env` file exists anywhere
**Root cause:** Neither the current repo directory nor the old project
directory (see Issue 2) has a real `.env`. The running containers only
have their env vars because they were created once, in the past, with
values supplied at that time (`N8N_BASIC_AUTH_USER=admin`,
`POSTGRES_DB=qa_agent`, etc. — matching `.env.example`'s defaults) — the
file itself is gone now. A fresh `docker compose up` from this repo today
would start with those variables unset/empty.

**Smallest fix:** `cp .env.example .env` in `QA-Engineer/`, fill in real
values for `N8N_BASIC_AUTH_PASSWORD`, `POSTGRES_PASSWORD`,
`ANTHROPIC_API_KEY`, and (when available) the Jira/HTTP-auth variables.
No code change.

### Issue 2 — Running containers are bound to a stale, moved project directory
**Root cause:** `docker inspect` shows the `n8n` container's bind mounts
resolve to `Desktop/qa-test-agent/reports` and
`Desktop/qa-test-agent/test-scripts` — not `Desktop/Qa agent/QA-Engineer`.
The Compose project label confirms it: these containers were created by
running `docker compose up -d` from `Desktop/qa-test-agent` before the
project was renamed/relocated to `Desktop/Qa agent/QA-Engineer`. That old
directory still exists but now only contains empty `db/`, `reports/`,
`test-scripts/` folders (no `docker-compose.yml`, no `.env` — those moved
with the rest of the repo). The result: the live containers can see none
of this repo's actual content — `/data/test-scripts` inside the `n8n`
container is empty, so no sample test script (including the newly-added
`full-api-test-script.xlsx`) is reachable by a real pipeline run.

Postgres is the one exception — its schema (`runs`/`decisions`/
`jira_tickets`) already matches `db/init/001_init_schema.sql` exactly,
because that container's data volume was initialized once from this
schema before the move and has persisted since. All three tables are
empty, so nothing is lost either way.

**Smallest fix:**
```bash
# from the OLD directory, to cleanly release the stale containers/network
docker compose -p qa-test-agent down

# from the ACTUAL repo, after Issue 1's .env is in place
cd "Desktop/Qa agent/QA-Engineer"
docker compose up -d
```
This recreates the containers with bind mounts pointing at the real
`reports/` and `test-scripts/` in this repo. Note the new Compose project
name will default to `qa-engineer` (from the folder name), so Postgres
will get a **new, empty** data volume — acceptable here since the old
volume has 0 rows in all 3 tables (confirmed above), so
`db/init/001_init_schema.sql` will simply re-run and recreate the same
schema with nothing to lose. No code change required either way.

### Issue 3 — No workflows imported or activated
**Root cause:** This n8n instance has never had `01-ingestion.json`
through `07-jira-agent.json` imported — it only has the default empty
"My workflow" n8n creates on first run. This matches `PROJECT_STATUS.md`'s
own tracking ("not yet imported/run inside a live n8n instance" on every
task) — expected at this point, not a regression, but it is the reason
the pipeline cannot execute yet.

**Smallest fix:** Once Issue 2 is resolved (correct instance, correct
mounts), import all 8 files from `n8n/workflows/` via the n8n UI
(Workflows → Import from File) and activate each, per the "Local dev
loop" in `docs/architecture/repository-design.md`. Manual UI step, no
code change — this is the natural first action of Task I-2, not part of
I-1's scope.

### Issue 4 — No credentials configured (flag for I-2, not a fix here)
**Root cause:** `n8n export:credentials --all` returns no results. The
Anthropic API call in `05-decision-orchestrator.json`
(`https://api.anthropic.com/v1/messages`) and any future Jira credential
have no corresponding n8n credential entry yet — consistent with
`PROJECT_STATUS.md`: "AI path... never been tested against a real
Anthropic credential."

**Recommendation:** Not a blocker for I-1 (infrastructure exists and is
reachable independent of credentials), but it **will** block the first
end-to-end run in I-2. Add an Anthropic credential (and Jira credential,
once that layer is exercised) via the n8n UI once Issue 2/3 are resolved.
No code or contract change needed — `ANTHROPIC_API_KEY` is already in
`.env.example`.

---

## Non-blocking observations

- `05-decision-orchestrator.json` calls the real Anthropic API
  (`api.anthropic.com`), not Ollama, directly — Ollama (Task 4.5) was
  used only in an out-of-band script harness for benchmarking, it is not
  wired into any workflow node. Ollama being installed/available on the
  host is good to have but isn't on the critical path for a live n8n run
  unless a workflow is deliberately re-pointed at it later.
- n8n startup log shows the internal Python task runner failed to start
  ("Python 3 is missing") — harmless here since every workflow uses
  `n8n-nodes-base.code` (JavaScript), never a Python code node.
- Several unrelated Docker containers from other projects are present on
  this machine (`taalverse_*`, `myrytha-*`, `jenkins`, etc.) — not
  touched, not in scope.

---

## Definition of Done

- [x] Infrastructure is verified — Docker/n8n/Postgres/Ollama/model
      availability confirmed; workflow JSON validity confirmed; mount,
      env, credential, and import/activation gaps identified.
- [x] All blockers documented — Issues 1–4 above, each with root cause
      and smallest recommended fix.
- [ ] Environment ready for Task I-2 — **not yet**: Issues 1–3 must be
      resolved (new `.env`, containers recreated from the correct
      directory, workflows imported/activated) before an end-to-end run
      can be attempted. Issue 4 (credentials) blocks the AI/Jira stages
      specifically and should be resolved in the same pass.

Stopping here per Task I-1 scope — no fixes applied, no workflow logic
touched.
