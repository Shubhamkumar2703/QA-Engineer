# qa-test-agent

AI agent pipeline that takes a test script, executes API-level test cases,
writes results to an Excel report, and files Jira tickets for failures —
with a human approval step before anything gets created in Jira.

See `docs/architecture/milestone-1.md` for the full system design and
`docs/architecture/repository-design.md` for the layout and conventions
this repo follows. Significant technical choices are recorded in
`docs/decisions/`.

Every workflow follows the conventions in `docs/workflow-standards.md` and
communicates using the shared JSON shapes documented in `docs/contracts/`
(`planner-contract.md` for the ingestion → Planner hand-off,
`error-payload.md` for validation failures) — read those before adding or
changing a workflow.

## Quickstart

```bash
git clone <this-repo>
cd qa-test-agent
cp .env.example .env
# edit .env with real values (n8n auth, Postgres creds, API keys)
docker compose up -d
```

Then open `http://localhost:5678` for n8n (log in with the
`N8N_BASIC_AUTH_USER` / `N8N_BASIC_AUTH_PASSWORD` you set in `.env`), and
import the latest workflow JSON from `n8n/workflows/`.

## Status

Milestone 1. Task 1 (repository + Docker Compose + n8n + Postgres) is
still in progress. Task 2 (Excel ingestion workflow,
`n8n/workflows/01-ingestion.json`) and Task 2.5 (workflow standards +
shared contracts) have been built but not yet verified inside a running
n8n instance — see `docs/architecture/milestone-1.md` for the full task
breakdown and `PROJECT_STATUS.md` for current task status.
