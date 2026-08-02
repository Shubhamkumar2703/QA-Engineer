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
(see `docs/contracts/README.md` for the full list — currently the Planner
Contract, the API Request Contract, the HTTP Response Contract, the
Normalized Response Contract, and the shared Error Payload) — read those
before adding or changing a workflow.

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
still in progress. Task 2 (Excel ingestion), Task 2.5 (workflow standards
+ shared contracts), Task 3.1 (API Request Builder,
`n8n/workflows/02-api-request-builder.json`), Task 3.2 (HTTP Executor,
`n8n/workflows/03-http-executor.json`), and Task 3.3 (Response
Normalizer, `n8n/workflows/04-response-normalizer.json`) have been built
but not yet verified inside a running n8n instance — see
`docs/architecture/milestone-1.md` for the full task breakdown and
`PROJECT_STATUS.md` for current task status.

"API Agent" (Milestone 1's original Task 3) has been built as three
sub-workflows: 3.1 API Request Builder (done — prepares a request, never
sends it), 3.2 HTTP Executor (done — sends the prepared request, captures
the raw response, never judges PASS/FAIL), 3.3 Response Normalizer (done
— folds a successful response or a transport failure into one stable
contract for the Decision Agent, still never judging PASS/FAIL). See the
numbering note in `docs/workflow-standards.md`. Task 4 (Decision Agent)
is next and not yet started.
