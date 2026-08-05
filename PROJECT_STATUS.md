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
| Task 4.4 - Confidence & Trust Layer | `05-decision-orchestrator.json` (same file, extended) | Done. Replaced the single "Validate Decision Contract" node with "Validate AI Response Shape" -> "Ground Evidence" -> "Apply Trust Rules": structured field/value evidence grounding (not natural-language comparison), deterministic confidence capping (no longer passed through raw), hallucination detection (forces `MANUAL_REVIEW`), and a new `UNGROUNDED_VERDICT` error for internally-inconsistent verdicts. Script harness: 82/82 checks, no regression to Tier 0/1 or contract shape. See "Verification notes" below. |
| Task 4.5 - Verification, Benchmark & Calibration | `docs/reviews/task-4.5-verification.md` | Done. No workflow changes required - the shipped `05-decision-orchestrator.json` was correct against every real test. First real (not mocked) LLM verification in this project: 5 live calls to a local Ollama server (`llama3:latest`), which surfaced a real malformed-JSON response and a real "confidently wrong despite fully-grounded evidence" case. **Milestone 1 Decision Engine marked production-ready for local testing** (Ollama), with real Anthropic API + live n8n execution still unverified. See "Verification notes" below and the full report. |
| Task 5 - Documentation Agent | `06-documentation-agent.json` | Built. Consumes only the Decision Contract and produces the new Report Contract (`docs/contracts/report-contract.md`) - formatting only, no AI call, no Excel/PDF/Sheets/dashboard/Jira-specific logic anywhere in this file. Script harness: 61/61 checks. See "Verification notes" below. |
| Task 5.1 - Excel Writer | `06.1-excel-writer.json` | Built. First Report Contract renderer, follows the new Renderer Adapter → COLUMN_MAP → Renderer pattern (`docs/renderers/excel-renderer.md`). Consumes only the Report Contract - never a Decision Contract, never AI. Updates only the 9 renderer-owned columns on the matching row; `Test ID`/`Description`/`Steps`/`Expected Result` are never referenced in its column map, so they can't be written by construction. Script harness: 113/113 checks. See "Verification notes" below. |
| Task 6 - Jira Agent | `07-jira-agent.json` | Built. Consumes only the Report Contract - never a Decision Contract - and produces the new Jira Draft Contract (`docs/contracts/jira-draft-contract.md`). Drafts for `FAIL` always, `MANUAL_REVIEW` only if `DRAFT_ON_MANUAL_REVIEW` is enabled (off by default); never for `PASS`/`BLOCKED`. No AI call, no direct Jira API call anywhere in this file - Duplicate Check/Draft Ticket/Human Approval/Create-Update Jira are documented NoOp extension points. Script harness: 62/62 checks. See "Verification notes" below. |

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

**Task 4.4 (Confidence & Trust Layer):** Replaced "Validate Decision
Contract" with three nodes - "Validate AI Response Shape" (structural
only, tightened to reject empty evidence), "Ground Evidence" (parses
each evidence string into a `{field, value}` token per the model's own
documented format and resolves it against `__evidence_packet` -
structural matching, never natural-language comparison), and "Apply
Trust Rules" (the only node that turns grounding results into a
decision: fully ungrounded evidence forces `MANUAL_REVIEW` regardless of
what the model reported; partial grounding caps confidence to 0.5, which
combined with the existing 0.7 threshold always also ends in
`MANUAL_REVIEW`; a `PASS`/`FAIL` below a 0.3 decisive-confidence floor is
rejected outright as the new `UNGROUNDED_VERDICT` error, since it's
self-contradictory rather than merely uncertain). Confidence is no
longer passed through raw even when fully grounded - capped at 0.95
(structured expectation) or 0.75 (free-text only). Reasoning/evidence
text is never rewritten, only status/confidence/next_action are ever
adjusted. Re-ran the full harness plus 14 new checks: 82/82 passed, zero
regression to Tier 0/1 or the Decision Contract's shape.

**Task 4.5 (Verification, Benchmark & Calibration):** Full report at
`docs/reviews/task-4.5-verification.md`. The headline: this is the
**first task to test the AI path against a real model** rather than a
scripted response - 5 live calls to a local Ollama server
(`llama3:latest`), with genuine timing/token/prompt-size data. Confirmed
end-to-end (Tier 0/1 deterministic, Tier 2 real-model) with zero
workflow changes required. Two real (not hypothetical) findings: a
malformed/truncated JSON response from the real model (correctly
rejected by `Validate AI Response Shape`, exactly as designed), and a
case where the model cited fully real, correctly-grounded evidence and
still drew the wrong conclusion from it (`PASS` at 0.95 confidence for a
verdict its own `reasoning` field describes as a contradiction) - the
Trust Layer's structural grounding check has no way to catch this, since
nothing about it is structurally wrong. Confidence-threshold calibration
is inconclusive (this benchmark's samples didn't land near the 0.3/0.7
boundaries), not confirmed-good. Existing 82-check regression suite:
zero regressions.

**Task 5 (Documentation Agent):** `06-documentation-agent.json` consumes
only the Decision Contract (`docs/contracts/decision-contract.md`) and
produces the new Report Contract (`docs/contracts/report-contract.md`) -
`{workflow_version, report_version, test_case, decision, report}`. Three
nodes: `Validate Contract` (envelope check, mirrors every prior
workflow's convention - upstream ERROR payloads pass through unchanged),
`Route Validation Errors` (same IF-node pattern as every prior workflow),
`Build Report Contract` (the only real work - every `report.*` field is
either carried forward unchanged or built via a fixed lookup table /
string template, never generated). No AI call anywhere in this file - the
Documentation Agent's job is formatting a verdict that was already
decided, not deciding anything. No Excel, Google Sheets, PDF, dashboard,
or Jira reference anywhere in the workflow or the contract it produces -
those are downstream renderer workflows (Task 5.1+), a deliberate design
decision so the same Report Contract works for all of them. Same
script-harness approach as every prior task - `Validate Contract` and
`Build Report Contract` extracted from the committed JSON and chained as
n8n would connect them. 61/61 checks passed: a deterministic-tier `PASS`
and an `ai_assisted`-tier `FAIL`/`BLOCKED`/`MANUAL_REVIEW` each verified
for `test_case`/`decision` preservation (byte-for-byte, via
`JSON.stringify` equality against the source Decision Contract), correct
`report.actual_result` extraction across all three evidence-rendering
conventions the pipeline currently produces (`status_code: expected X,
actual Y` from Tier 1, `transport.status: X` from Tier 0, `actual_status:
X` from the AI path), `report.manual_review` set correctly, the four
fixed `tester_notes` templates, and that no renderer name
(excel/pdf/sheets/jira/dashboard) appears anywhere in a produced Report
Contract. Plus: an upstream ERROR payload passes through `Validate
Contract` unchanged, and 8 malformed-Decision-Contract cases (missing
`verdict`, invalid status enum, out-of-range confidence, empty evidence,
missing `decision_basis.tier`, missing `metadata.decided_at`, non-object
input, array input) all produce `INVALID_DECISION_CONTRACT`. Not yet
imported/run inside a live n8n instance, same caveat as every prior
workflow.

**Task 5.1 (Excel Writer):** `06.1-excel-writer.json` is the first
renderer to consume the Report Contract, built around the new four-stage
Renderer Adapter → COLUMN_MAP → Renderer pattern documented in
`docs/renderers/excel-renderer.md`. `Excel Adapter` reads `report.*`/
`test_case.*` (the only node that does); `Apply Column Map` is the single
source of truth for the workbook's real column headers; `Locate & Merge
Row` does a read-modify-write over the whole workbook (every row read,
exactly one row updated, the full set written back), so every other row
and every non-renderer-owned column on the target row is preserved by
construction, not by a runtime check. Same script-harness approach as
every prior task (no live n8n available) - `Validate Contract`, `Excel
Adapter`, `Apply Column Map`, `Locate & Merge Row`, `Expand Rows For
Write`, `Build Write Confirmation`, and the two error-builder nodes
extracted from the committed JSON and chained as n8n would connect them,
against a synthetic 3-row workbook standing in for a parsed xlsx file
(the native `readWriteFile`/`spreadsheetFile` nodes have no custom JS to
extract - the same substitution this project's harnesses have always used
for native nodes, e.g. 05's `Claude` HTTP node). 113/113 checks passed:
all four verdict statuses (`PASS`/`FAIL`/`BLOCKED`/`MANUAL_REVIEW`)
correctly update all 9 renderer-owned columns on the correct row while
leaving `Test ID`/`Description`/`Steps`/`Expected Result` and the two
non-target rows byte-for-byte unchanged; running the same Report Contract
through the pipeline twice in a row (second run reading the first run's
output) produces byte-for-byte identical final rows (idempotency); an
upstream ERROR payload passes through unchanged; 8 malformed-Report-
Contract cases all produce `INVALID_REPORT_CONTRACT`; and a `test_id`
with no matching row produces `TARGET_ROW_NOT_FOUND` rather than
appending a new row. Not yet imported/run inside a live n8n instance, and
the actual xlsx read/write behavior of `n8n-nodes-base.readWriteFile` /
`n8n-nodes-base.spreadsheetFile` is unverified against a real file - only
this workflow's own Code-node logic was exercised.

**Task 6 (Jira Agent):** `07-jira-agent.json` consumes only the Report
Contract (`docs/contracts/report-contract.md`) and produces the new Jira
Draft Contract (`docs/contracts/jira-draft-contract.md`) -
`{workflow_version, jira_version, report, jira}`. `Validate Contract`
(envelope check, same upstream-ERROR-passthrough convention as every
prior workflow) → `Route Validation Errors` (same IF pattern) → `Build
Jira Draft Contract` (the only real work - every `jira.*` field is either
reused verbatim from the Report Contract, the routing decision it already
carries (`decision.verdict.next_action` → `priority`, never a re-derived
confidence threshold), or built via a fixed lookup table (`labels`,
`components`)) → `Duplicate Check (Extension Point)` (NoOp, architecture
only per this task's scope) → `Draft Required?` (IF on `jira.required`)
→ `Draft Ticket` → `Human Approval` → `Create / Update Jira` (all three
documented NoOp hand-offs, no Jira API call anywhere in this file) or
`No Draft Required`, converging at `Jira Layer Complete`. Same
script-harness approach as every prior task - `Validate Contract` and
`Build Jira Draft Contract` extracted from the committed JSON and chained
as n8n would connect them. 62/62 checks passed: `PASS`/`BLOCKED` produce
`jira.required: false` with every other `jira.*` field null/empty (never
fabricated); `FAIL` always produces a required draft with all nine
deterministic fields verified individually (summary template, reasoning
reused verbatim as description, `test_case.expected_result`/`steps`
reused unchanged, `decision.verdict.evidence` reused verbatim, priority
correctly split `High`/`Medium` by `next_action`, labels/components
correct); `MANUAL_REVIEW` verified both with `DRAFT_ON_MANUAL_REVIEW` off
(default - no draft) and patched on (draft with `Medium` priority and a
`manual-review` label, not `needs-triage`); an upstream ERROR payload
passes through `Validate Contract` unchanged; 9 malformed-Report-Contract
cases all produce `INVALID_REPORT_CONTRACT`; and two runs of the same
input produce byte-for-byte identical drafts (determinism). Not yet
imported/run inside a live n8n instance, same caveat as every prior
workflow. Duplicate Check, Draft Ticket, Human Approval, and Create /
Update Jira remain unimplemented NoOp extension points by design - no
real Jira API call exists anywhere in this project yet.

## Next up

Milestone 1 Integration - every stage from ingestion (01) through the
Jira Agent (07) now has a producer, and the pipeline's contract chain
(Planner → API Request → HTTP Response → Normalized Response → Decision
→ Report → Excel/Jira Draft) is complete end-to-end on paper. The
largest unclosed gaps, none of them new to this task: (1) nothing has
ever run inside a live n8n instance - every workflow so far has only been
verified via extracted-Code-node script harnesses; (2) the AI path has
never been tested against a real Anthropic credential, only Ollama
(Task 4.5) and mocks; (3) real xlsx read/write behavior
(`readWriteFile`/`spreadsheetFile`) is unverified against an actual file;
(4) don't treat high AI confidence as a correctness guarantee - a real
false-positive was demonstrated at 0.95 in Task 4.5; (5) the Jira Layer's
Duplicate Check → Draft Ticket → Human Approval → Create/Update Jira
chain is architecture-only - no real Jira API integration exists. An
end-to-end integration pass (a real n8n instance, one test script,
through all seven workflows) is the natural next milestone activity
before adding new capability.
