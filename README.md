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
Normalized Response Contract, the Decision Contract, the Report Contract,
and the shared Error Payload) — read those before adding or changing a
workflow.

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
`n8n/workflows/03-http-executor.json`), Task 3.3 (Response Normalizer,
`n8n/workflows/04-response-normalizer.json`), and all of Task 4 (Decision
Agent, `n8n/workflows/05-decision-orchestrator.json`) are built — see
`docs/architecture/milestone-1.md` for the full task breakdown and
`PROJECT_STATUS.md` for current task status.

"API Agent" (Milestone 1's original Task 3) has been built as three
sub-workflows: 3.1 API Request Builder (done — prepares a request, never
sends it), 3.2 HTTP Executor (done — sends the prepared request, captures
the raw response, never judges PASS/FAIL), 3.3 Response Normalizer (done
— folds a successful response or a transport failure into one stable
contract for the Decision Agent, still never judging PASS/FAIL). See the
numbering note in `docs/workflow-standards.md`.

**Task 4 (Decision Agent) is complete.** 4.0 established the design (ADR
005, the Decision Contract, prompt v1 —
`docs/architecture/decision-agent-design.md`); 4.1 built the
orchestrating three-tier funnel (`BLOCKED`/`PASS` deterministically for
transport failures and exact status-code matches, AI only for everything
else); 4.2 extracted the deterministic Tier 0/1 logic into a reusable
"Decision Engine" node group; 4.3 split prompt construction into a
dedicated "Prompt Builder" stage, isolated from the Anthropic API-call
structure; 4.4 added a Confidence & Trust Layer (evidence grounding
against the real evidence packet, deterministic confidence capping,
hallucination detection); 4.5 verified the complete flow end-to-end,
including — for the first time — against a **real, locally-running
Ollama model**, not just scripted responses. See
`docs/reviews/task-4.5-verification.md` for the full benchmark/
calibration report.

**Decision Engine status: production-ready for local testing (Ollama)**,
with two gaps still open before it's fully verified: no real Anthropic
API call has ever been tested (only mocked), and nothing has run inside
a live n8n instance yet (every task has verified via extracted node code
in a script harness). The Task 4.5 report also documents a real,
reproduced finding worth knowing before trusting AI verdicts at face
value: a model can cite fully real, correctly-grounded evidence and
still draw the wrong conclusion from it — the Trust Layer's grounding
check is structural, not semantic, and doesn't catch that case.

**Task 5 (Documentation Agent) is complete.**
`n8n/workflows/06-documentation-agent.json` consumes a validated Decision
Contract and produces the new Report Contract
(`docs/contracts/report-contract.md`) — the canonical, output-format-
independent QA report record that Excel, PDF, Google Sheets, dashboards,
and Jira will all read as downstream renderers. It performs formatting
only: no AI call, no re-judgment, and no renderer-specific field or logic
anywhere in the workflow or the contract it produces. Verified with the
same script-harness approach as every prior workflow (61/61 checks) —
still not yet imported/run inside a live n8n instance. See
`PROJECT_STATUS.md` for the full verification notes.

**Task 5.1 (Excel Writer) is complete.**
`n8n/workflows/06.1-excel-writer.json` is the first renderer built on top
of the Report Contract, and establishes the pattern every future renderer
follows: `Renderer Adapter → COLUMN_MAP → Renderer` (see
`docs/renderers/excel-renderer.md`). It consumes only the Report
Contract — never a Decision Contract — locates the matching row by Test
ID, and updates only the nine renderer-owned columns (Status, Actual
Result, Notes, Tester Notes, Confidence, Decision Basis, Manual Review,
Execution Date, Evidence Summary); the original test definition (Test ID,
Description, Steps, Expected Result) is structurally impossible for this
workflow to write, since those columns never appear in its column map at
all. Read-modify-write over the whole workbook keeps every other row, and
every other column on the updated row, byte-for-byte untouched, and makes
reruns idempotent. Verified with the same script-harness approach as
every prior workflow (113/113 checks, including a byte-for-byte
idempotency check across two consecutive runs) — still not yet imported/
run inside a live n8n instance, and real xlsx read/write behavior remains
unverified against an actual file. See `PROJECT_STATUS.md` for the full
verification notes.
