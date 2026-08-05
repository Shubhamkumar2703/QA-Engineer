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

## Next up

Task 5 (Documentation Agent). Before it, per the Task 4.5 report's
recommendations: don't treat high AI confidence as a correctness
guarantee (a real false-positive was demonstrated at 0.95); prioritize a
real n8n + real Anthropic credential verification pass, still the
largest unclosed gap across every Task 4 sub-task; and note that a
semantic-consistency check (does the verdict follow from the reasoning,
not just is the evidence grounded) is now a concretely-scoped, evidenced
future capability, not a hypothetical one.
