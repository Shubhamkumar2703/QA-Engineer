# Project Status

Tracks Milestone 1 task status. See `docs/architecture/milestone-1.md` for
the full task breakdown and `docs/workflow-standards.md` for the
sub-workflow numbering (`01-ingestion` ... `07-jira-agent`).

## Milestone 1

| Task | Workflow | Status |
|---|---|---|
| Task 1 - Repository + Docker Compose + n8n + Postgres | - | In progress |
| Task 2 - Excel Ingestion | `01-ingestion.json` | Built, not yet verified inside a running n8n instance |
| Task 2.5 - Workflow standards + shared contracts | `docs/workflow-standards.md`, `docs/contracts/` | Done |
| Task 3.1 - API Request Builder | `02-api-request-builder.json` | Built, not yet verified inside a running n8n instance |
| Task 3.2 - HTTP Executor | `03-http-executor.json` | Built (`workflow_version: "1.1"` - see Task 3.3 defect-fix note below). Node logic verified against a real target (httpbin.org) via a script harness outside n8n - see "Verification notes" below. Not yet imported/run inside a live n8n instance. |
| Task 3.3 - Response Normalizer | `04-response-normalizer.json` | Built. Node logic verified with a script harness (197/197 checks) against synthetic HTTP Response Contracts and HTTP Executor ERROR payloads - see "Verification notes" below. Not yet imported/run inside a live n8n instance. |
| Decision Agent | `05-decision-agent.json` | Not started |
| Documentation Agent | `06-documentation-agent.json` | Not started |
| Jira Agent | `07-jira-agent.json` | Not started |

## Verification notes

**Task 3.2 (HTTP Executor):** No running n8n instance was available in
this environment, so the workflow's own Code-node logic (validation,
authentication resolution, response/error contract building) was
exercised directly - loaded from the committed workflow JSON and run
against real HTTP responses from httpbin.org, plus real timeout and
connection-refused conditions - rather than against a mocked
reimplementation. 89/89 checks passed. Before this workflow is trusted in
a real run, it still needs to be imported into a live n8n instance and
executed end-to-end from `02-api-request-builder`'s output, per the
"Local dev loop" in `docs/architecture/repository-design.md`.

**Task 3.2 critical-defect fix (done during Task 3.3):** every ERROR
payload `03-http-executor.json` produces now carries `test_case` and
`expected` in `details` (`workflow_version` bumped `1.0` → `1.1`,
contract shape unchanged). Without this, the Response Normalizer could
not satisfy its own "preserve test_case"/"preserve expected" requirements
for any transport failure (timeout, connection refused, DNS failure,
pre-flight validation error) - those error payloads previously carried
neither. Re-ran the full Task 3.2 harness after the fix: 88/89 passed,
1 failure was httpbin.org rate-limiting flakiness unrelated to the
change (reproduced independently), not a regression. See
`AI_MEMORY.md` for detail.

**Task 3.3 (Response Normalizer):** Same approach as Task 3.2 - no live
n8n instance, so the workflow's Code-node logic was extracted from the
committed JSON and chained exactly as n8n would connect the nodes,
against synthetic HTTP Response Contracts and HTTP Executor ERROR
payloads covering every status code / transport failure the task
requires. 197/197 checks passed, including that `request_id`,
`response_id` (or its explicit `null`), `test_case`, and `expected` all
survive both the success path and every transport-failure path. Same
live-n8n verification caveat as Task 3.2 applies.

## Next up

Task 4 - Decision Agent: consumes the Normalized Response Contract
(`docs/contracts/normalized-response-contract.md`), compares
`transport`/`response` against `expected`, and produces the
`{status, confidence, reasoning, evidence, next_action}` verdict object
specified in ADR 004 and `docs/architecture/milestone-1.md` section 5.
This is the first workflow in the pipeline allowed to call an AI model.
