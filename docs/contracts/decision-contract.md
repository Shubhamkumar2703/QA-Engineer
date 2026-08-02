# Decision Contract

## Status
Accepted (introduced in Task 4.0)

## Purpose

The payload the Decision Agent produces after judging a Normalized
Response Contract (`docs/contracts/normalized-response-contract.md`)
against its `expected` value. This is the first contract in the pipeline
whose producer is allowed to call an AI model - every workflow before it
(01-04) is deliberately AI-free. It formalizes the
`{status, confidence, reasoning, evidence, next_action}` shape specified
in ADR 004 and `docs/architecture/milestone-1.md` section 5, updated per
ADR 005 (`docs/architecture/decisions/005-manual-review-replaces-not-run.md`).

See `docs/architecture/decision-agent-design.md` for the full reasoning
design (the tier funnel, evidence rules, confidence calculation,
hallucination guards, and cost strategy) this contract is the output of.
This document only specifies the shape; the design document specifies
how that shape gets filled in.

## Producer

`n8n/workflows/05-decision-orchestrator.json` (Task 4.1). Named
"orchestrator" rather than "agent" because it decides *when* AI is
needed and validates what comes back, rather than being the AI call
itself - see `docs/architecture/decisions/005-manual-review-replaces-not-run.md`
and `docs/workflow-standards.md`'s numbering table. "Decision Agent"
remains the conceptual role name used elsewhere in this project's docs
(e.g. `docs/architecture/milestone-1.md` section 5); this workflow file
is that role's Task 4.1 implementation, not a different concept.

## Consumer

The future Documentation Agent (writes the Excel row for every verdict)
and Jira Agent (drafts a ticket for `next_action: "create_jira"` only) -
both Task 4+, not yet built.

Not every item this workflow outputs is a Decision Contract - an input
this workflow cannot make sense of (a malformed Normalized Response
Contract, a schema-invalid model response after retry, see
`docs/architecture/decision-agent-design.md` section 7) produces the
shared error object instead (`docs/contracts/error-payload.md`), exactly
as every prior workflow does. Consumers must check
`item.status === 'ERROR'` before assuming an item is a Decision Contract.

**Note the naming collision to watch for:** an ERROR payload's own field
is also called `status` (always the literal string `"ERROR"`), and a
*valid* Decision Contract's judgment field is nested at
`verdict.status` (one of `PASS`/`FAIL`/`BLOCKED`/`MANUAL_REVIEW`), not at
the top level. Checking `item.status === 'ERROR'` first, before ever
reading `item.verdict`, is what keeps these two `status` fields from
being confused - see "Compatibility rules" below.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`05-decision-agent.json`), currently `"1.0"`. |
| `contract_version` | string | Version of **this contract's shape**, currently `"1.0"`. Same split rationale as every prior contract in this folder. |
| `request_id` | string \| null | Preserved unchanged from the Normalized Response Contract. |
| `response_id` | string \| null | Preserved unchanged from the Normalized Response Contract (`null` on a transport failure, per that contract's own rule). |
| `test_case` | object \| null | Preserved unchanged from the Normalized Response Contract. Never re-derived, never re-parsed - Documentation/Jira agents read the same `test_case` every workflow before this one has already carried forward. |
| `verdict` | object | `{ status, confidence, reasoning, evidence, next_action }` - see below. The only object in this contract this workflow actually *computes*; everything else is carried forward. |
| `decision_basis` | object | `{ tier, model_version, prompt_version }` - auditability metadata distinguishing a $0 deterministic verdict from a paid model call. See "decision_basis" below. |
| `metadata` | object | `{ decided_at, source_workflow, next_workflow }`. `source_workflow` is always `"04-response-normalizer"`; `next_workflow` is always `"06-documentation-agent"` (see the naming-scheme table in `docs/workflow-standards.md` - Jira Agent is a parallel consumer of the same output, not a different `next_workflow` value; routing to both is an orchestration detail for Task 4's workflow, not a contract-shape concern). |

### `verdict` object

| Field | Type | Description |
|---|---|---|
| `status` | string | One of `PASS`, `FAIL`, `BLOCKED`, `MANUAL_REVIEW` (ADR 005). Each has exactly one trigger condition - see "Verdict states" below. Never any other value, never free-form prose (ADR 004). |
| `confidence` | number | `0.0`-`1.0`. `1.0` always for a deterministic verdict (Tiers 0-1, `decision_basis.tier !== "ai_assisted"`). For an AI-assisted verdict, a **rules-anchored** score - the model's self-reported confidence capped by evidence-quality rules, never the model's self-report taken directly. See `docs/architecture/decision-agent-design.md` section 3. |
| `reasoning` | string | Human-readable explanation. Templated for Tiers 0-1 (e.g. `"Expected status 422, received 422. Deterministic status-code match, no AI reasoning required."`); model-authored for Tier 2, constrained to facts present in the evidence packet (see the design doc's hallucination guards). |
| `evidence` | array of strings | Specific, checkable statements the verdict rests on (e.g. `"expected_status: 422"`, `"actual_status: 200"`). Every entry must be grounded in the Normalized Response Contract's `expected`/`transport`/`response` fields - an entry that isn't traceable to those fields is a hallucination-guard failure, not a valid Decision Contract (see the design doc's grounding check). |
| `next_action` | string | One of `write_report`, `create_jira`, `flag_for_review`, `none` (ADR 005). Downstream agents branch on this field alone - they never re-derive routing from `status`, `confidence`, or `reasoning` (`docs/workflow-standards.md`'s "nothing downstream re-derives a value another workflow already computed" rule). |

### `decision_basis` object

| Field | Type | Description |
|---|---|---|
| `tier` | string | One of `deterministic_transport` (Tier 0 - `BLOCKED`, no AI), `deterministic_exact_match` (Tier 1 - exact status-code match, no AI), `ai_assisted` (Tier 2 - a model call was made). See `docs/architecture/decision-agent-design.md` section 1 for the tier funnel. |
| `model_version` | string \| null | The model that produced the verdict (e.g. `"claude-haiku-4-5-20251001"`). `null` for Tiers 0-1 - no model was involved. |
| `prompt_version` | string \| null | The versioned prompt file used (e.g. `"v1"`, matching `prompts/decision-agent/v1.md`). `null` for Tiers 0-1. |

## Optional fields

None yet. As with every prior contract in this folder, consumers should
ignore unknown fields rather than fail on them.

---

## Verdict states

Each state has exactly one trigger; no test case can reach more than one
path (see `docs/architecture/decision-agent-design.md` section 4 for the
full reasoning):

| `verdict.status` | Trigger | `verdict.next_action` |
|---|---|---|
| `BLOCKED` | `transport.status_code === null` on the input Normalized Response Contract - no real response was ever received. A statement about the pipeline, never about the API under test. | `none` |
| `PASS` | A real response was received and satisfies `expected`, at `confidence >= 0.7`. | `write_report` |
| `FAIL` | A real response was received and contradicts `expected`, at `confidence >= 0.7`. | `create_jira` if `confidence >= 0.8`, otherwise `flag_for_review` (filing a ticket is a real-world action with a human cost - it demands a higher bar than reporting alone). |
| `MANUAL_REVIEW` | A real response was received, a judgment was attempted, but confidence fell below `0.7`, evidence was insufficient, or a hallucination guard rejected the model's output. | `flag_for_review` |

---

## Example payloads

**A deterministic PASS (Tier 1 - no AI call):**

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "response_id": "a2c9e410-9e3b-4f1a-8b2d-3e6f1a7c9d0b",
  "test_case": {
    "test_id": "AUTH-022",
    "description": "Verify successful login",
    "expected_result": "200 OK",
    "verification_type": "api"
  },
  "verdict": {
    "status": "PASS",
    "confidence": 1.0,
    "reasoning": "Expected status 200, received 200. Deterministic status-code match, no AI reasoning required.",
    "evidence": ["expected_status: 200", "actual_status: 200"],
    "next_action": "write_report"
  },
  "decision_basis": {
    "tier": "deterministic_exact_match",
    "model_version": null,
    "prompt_version": null
  },
  "metadata": {
    "decided_at": "2026-08-02T10:00:00.000Z",
    "source_workflow": "04-response-normalizer",
    "next_workflow": "06-documentation-agent"
  }
}
```

**An AI-assisted FAIL (Tier 2):**

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "b1c2d3e4-5678-4abc-9def-1234567890ab",
  "response_id": "c2d3e4f5-6789-4bcd-8ef0-234567890abc",
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "expected_result": "422 Unprocessable Entity",
    "verification_type": "api"
  },
  "verdict": {
    "status": "FAIL",
    "confidence": 0.95,
    "reasoning": "Expected 422 Unprocessable Entity for a 5-character password; API returned 200 OK and created the account.",
    "evidence": ["expected_status: 422", "actual_status: 200", "response_body.created: true"],
    "next_action": "create_jira"
  },
  "decision_basis": {
    "tier": "ai_assisted",
    "model_version": "claude-haiku-4-5-20251001",
    "prompt_version": "v1"
  },
  "metadata": {
    "decided_at": "2026-08-02T10:00:05.400Z",
    "source_workflow": "04-response-normalizer",
    "next_workflow": "06-documentation-agent"
  }
}
```

**A transport BLOCKED (Tier 0 - no AI call):**

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "d3e4f5a6-7890-4cde-9f01-34567890abcd",
  "response_id": null,
  "test_case": {
    "test_id": "AUTH-023",
    "description": "Verify rate limiting",
    "expected_result": "429 Too Many Requests",
    "verification_type": "api"
  },
  "verdict": {
    "status": "BLOCKED",
    "confidence": 1.0,
    "reasoning": "No response was received: transport.status = TIMEOUT.",
    "evidence": ["transport.status: TIMEOUT"],
    "next_action": "none"
  },
  "decision_basis": {
    "tier": "deterministic_transport",
    "model_version": null,
    "prompt_version": null
  },
  "metadata": {
    "decided_at": "2026-08-02T10:00:10.000Z",
    "source_workflow": "04-response-normalizer",
    "next_workflow": "06-documentation-agent"
  }
}
```

(`test_case` shown truncated in all three examples for readability - the
real payload carries the full object per
`docs/contracts/planner-contract.md`.)

---

## What produces an ERROR instead

Every failure mode this workflow can itself produce becomes the shared
error object (`docs/contracts/error-payload.md`) with
`stage: "decision_agent"`. Shipped as of Task 4.1:

| Failure | `code` |
|---|---|
| Input isn't a well-formed Normalized Response Contract | `INVALID_NORMALIZED_RESPONSE_CONTRACT` |
| The model's response doesn't include the forced `return_verdict` tool call, or its input fails schema validation | `INVALID_MODEL_RESPONSE` |
| The AI provider call itself failed (network error, timeout, non-2xx) | `AI_SERVICE_UNAVAILABLE` |

Neither `INVALID_MODEL_RESPONSE` nor `AI_SERVICE_UNAVAILABLE` triggers a
retry - Task 4.1 validates and reports once; retry logic and AI-failure
recovery are explicitly out of scope for that task.

**Not yet shipped:** `UNGROUNDED_VERDICT`, anticipated for when a
hallucination guard rejects the model's output in a way that can't be
safely downgraded to `MANUAL_REVIEW`. This requires the grounding-check
logic Task 4.4 (Confidence & Hallucination Guards) introduces - Task 4.1
deliberately does not implement grounding validation.

A `MANUAL_REVIEW` verdict is **not** one of these - it is a normal,
successfully-produced Decision Contract. This workflow only produces an
ERROR payload when it cannot produce a verdict at all, not when the
verdict it produces is uncertain.

---

## Versioning

Same rules as every prior contract in this folder:

- Bump `contract_version` when this contract's *shape* changes (new
  required field, renamed field, changed meaning) - not for new optional
  fields or new error `code` values.
- Bump `workflow_version` when `05-decision-agent.json`'s internal logic
  changes in a way worth tracking, independent of whether the contract
  shape changed - this includes prompt changes (`prompt_version` inside
  `decision_basis` tracks the prompt itself; `workflow_version` tracks
  the workflow wrapping it, same split as `run_id`/`workflow_version`/
  `prompt_version`/`model_version` in `docs/architecture/milestone-1.md`
  section 7).

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field - see `docs/contracts/error-payload.md` and the naming-
  collision note under "Consumer" above.
- Consumers must ignore unknown top-level fields rather than reject them.
- Consumers must treat `verdict.next_action` as the single field that
  determines routing - never re-derive a routing decision from
  `verdict.status`, `verdict.confidence`, or `verdict.reasoning`.
- `verdict.reasoning`/`verdict.evidence` are for humans and for
  Documentation/Jira agents to *display*, never to re-parse for a
  decision - if a future consumer needs to branch on something
  `reasoning` currently only expresses in prose, that is a signal to add
  a new structured field, not to parse the prose.

## Future extension notes

- A future Repository/Database/UI agent (Milestone 2/3) does not consume
  this contract - it is specific to the API-test judgment path. Each
  verdict-producing path should get its own decision contract when it's
  built, not be forced into this one's shape.
- If a later milestone needs a second-opinion/escalation model call
  (`docs/architecture/decision-agent-design.md` section 8's cheap-model-
  first cascade), that is additive - a new `decision_basis.escalated`
  boolean or similar, not a change to what `verdict` means.
- `evidence` is currently a flat array of strings for human readability
  (matching the worked example in `docs/architecture/milestone-1.md`
  section 6). A future consumer needing structured evidence (e.g. to
  highlight specific response fields in a UI, Milestone 4) should get a
  parallel structured field rather than this one being reshaped out from
  under existing consumers.
