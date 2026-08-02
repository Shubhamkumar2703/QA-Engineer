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
| Task 4.0 - Decision Agent foundations | `docs/contracts/decision-contract.md`, ADR 005, `prompts/decision-agent/v1.md` | Done - design layer only, no workflow. See `docs/reviews/task-4.0-decision-agent-foundations-review.md`. |
| Task 4.1 - Decision Orchestrator | `05-decision-orchestrator.json` | Built. Tier 0/1 (deterministic) and Tier 2 (AI-assisted, response validation) logic verified with a script harness. AI call itself mocked (no live Anthropic credential in this environment) and not yet imported/run inside a live n8n instance. Deliberately does not implement confidence recalibration, grounding validation, retry logic, or AI-failure recovery - later tasks. |
| Task 4.2 - Decision Engine (extracted Tier 0/1) | `05-decision-orchestrator.json` (same file, refactored) | Done. Tier 0 + Tier 1 + final contract assembly consolidated into a named "Decision Engine" node group, using structured evidence objects internally (rendered to strings only at final assembly - `decision-contract.md`'s shape is unchanged). Script harness: 60/60 checks, no regression to Tier 2. See "Verification notes" below. |
| Task 4.3 - AI Evaluation (Prompt Builder) | `05-decision-orchestrator.json` (same file, extended) | Done. Split the former "Build AI Request" node into a dedicated "Prompt Builder" stage (evidence allow-list re-verification + prompt content) and "Build Claude API Request" (API-call structure only). Script harness: 68/68 checks, no regression to Tier 0/1/2. See "Verification notes" below. |
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

**Task 4.1 (Decision Orchestrator):** Same script-harness approach as
Tasks 3.2/3.3 - the workflow's Code-node logic was extracted from the
committed JSON and chained as n8n would connect the nodes. 50/50 checks
passed, covering: Tier 0 (BLOCKED, zero AI calls), Tier 1 (PASS, zero AI
calls), Tier 2 (exactly one AI call, evidence packet excludes
request_id/response_id/test_case internals per the design doc), the
confidence-threshold gate (a low-confidence PASS/FAIL from the model is
downgraded to MANUAL_REVIEW without altering the reported confidence
value), four distinct malformed-AI-output rejections (no tool_use block,
invalid status enum, out-of-range confidence, non-string evidence
entries), an AI-service-failure path (`AI_SERVICE_UNAVAILABLE`, one
output still produced), and that an upstream ERROR payload is routed
straight through without ever entering the tier engine or calling AI.
**The AI call itself is mocked** - no live Anthropic credential was
available in this environment, so the actual network call to Claude, and
therefore real-world prompt quality/calibration, is unverified.

**Task 4.2 (Decision Engine extraction):** Tier 0, Tier 1, and final
Decision Contract assembly (previously three loosely-related nodes) were
consolidated into a named "Decision Engine" node group with a dedicated
sticky note, and evidence is now built as structured objects internally
(e.g. `{ type: 'status_code', expected: 200, actual: 200 }`), rendered
to the array-of-strings shape `decision-contract.md` requires only at
final assembly - the contract itself is unchanged. Re-ran the Task 4.1
harness plus 10 new checks (evidence structure/rendering, full
traceability): 60/60 passed, including that the Tier 2/AI path is
byte-for-byte unaffected. See
`docs/reviews/task-4.0-decision-agent-foundations-review.md` for the
known gaps this doesn't close (confidence thresholds are uncalibrated
placeholders; the few-shot examples are untested against a real model).

**Task 4.3 (AI Evaluation - Prompt Builder):** Split the former "Build AI
Request" node (which conflated prompt content with API-call structure)
into "Prompt Builder" (re-verifies the evidence packet against the
allow-list - defense in depth on top of "Build Evidence Packet"'s own
construction - and builds the system prompt + user message) and "Build
Claude API Request" (owns only model/tool/API-call structure). Re-ran the
full harness plus 8 new checks, including a defense-in-depth test that
feeds Prompt Builder a deliberately leaked `request_id`/`jira_key` and
confirms both are stripped before reaching the model: 68/68 passed, zero
regression to Tier 0/1/2. Same "AI call is mocked, never run against a
real Anthropic API" caveat as Task 4.1 still applies.

## Next up

Per the Task 4 tree: 4.4 (Confidence & Hallucination Guards), 4.5
(Decision Contract Validation) - both refinements/hardening of what 4.1-
4.3 already built end-to-end (tier routing, the AI call with a dedicated
prompt stage, and basic schema validation all exist now; 4.4/4.5 add
grounding checks, retry logic, AI-failure recovery, and confidence
recalibration on top, per their own scope). Before any of them: import
`05-decision-orchestrator.json` into a real n8n instance with a real
Anthropic credential and run at least one Tier 2 case end-to-end -
nothing about the actual AI call has been verified
outside this environment's mocked harness.
