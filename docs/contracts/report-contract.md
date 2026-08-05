# Report Contract

## Status
Accepted (introduced in Task 5)

## Purpose

The payload the Documentation Agent produces after formatting a validated
Decision Contract (`docs/contracts/decision-contract.md`) into the
canonical QA report record. This is the single source of truth for all
future documentation outputs - Excel, PDF, Google Sheets, dashboards, and
Jira are all downstream **renderers** that read this contract; none of
them is this contract's producer, and this contract itself has no opinion
on, or knowledge of, any of them.

The Documentation Agent performs formatting only. Every field below is
either carried forward unchanged from the Decision Contract or derived
from it through a fixed, deterministic template (string concatenation,
lookup table, boolean check) - never generated. It never invokes an AI
model and never re-judges a verdict; that judgment already happened in
the Decision Contract this workflow consumes.

See `docs/architecture/decision-agent-design.md` for how the *verdict*
this contract documents was reached - this document only specifies how
that already-final verdict gets formatted for reporting.

## Producer

`n8n/workflows/06-documentation-agent.json` (Task 5).

## Consumer

Future renderer workflows: an Excel Writer (Task 5.1, not yet built),
and eventually PDF/Google Sheets/dashboard/Jira consumers. Each renderer
reads the same Report Contract and produces its own output format; none
of them changes what this contract means, and none is required for this
contract to be considered complete on its own.

Not every item this workflow outputs is a Report Contract - an input this
workflow cannot make sense of (a malformed Decision Contract, or an
upstream ERROR payload) produces the shared error object instead
(`docs/contracts/error-payload.md`), exactly as every prior workflow
does. Consumers must check `item.status === 'ERROR'` before assuming an
item is a Report Contract.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`06-documentation-agent.json`), currently `"1.0"`. |
| `report_version` | string | Version of **this contract's shape**, currently `"1.0"`. Same split rationale as `workflow_version`/`contract_version` in every prior contract in this folder - named `report_version` here rather than `contract_version` only because "Report Contract" already appears in the field's own document title; the versioning rules below are otherwise identical. |
| `test_case` | object | Preserved unchanged from the Decision Contract. Never re-derived, never re-parsed - the original test case is never modified by this workflow. |
| `decision` | object | `{ request_id, response_id, verdict, decision_basis, decided_at }` - the complete, unmodified decision this report documents, carried forward for traceability. See "decision" below. |
| `report` | object | The formatted documentation fields - see "report" below. This is the only object this workflow actually *builds*; `test_case` and `decision` are carried forward. |

### `decision` object

| Field | Type | Description |
|---|---|---|
| `request_id` | string \| null | Preserved unchanged from the Decision Contract. |
| `response_id` | string \| null | Preserved unchanged from the Decision Contract (`null` on a transport failure, per that contract's own rule). |
| `verdict` | object | The Decision Contract's `verdict` object, byte-for-byte unchanged - `{ status, confidence, reasoning, evidence, next_action }`. |
| `decision_basis` | object | The Decision Contract's `decision_basis` object, byte-for-byte unchanged - `{ tier, model_version, prompt_version }`. |
| `decided_at` | string (ISO 8601) | Preserved unchanged from the Decision Contract's `metadata.decided_at`. |

This object exists so a report row can always be traced back to the exact
decision it documents without re-deriving or re-fetching anything -
nothing in `decision` is ever rewritten or summarized; that formatting
happens only in `report` below.

### `report` object

| Field | Type | Description |
|---|---|---|
| `status` | string | `decision.verdict.status`, copied unchanged - one of `PASS`, `FAIL`, `BLOCKED`, `MANUAL_REVIEW`. |
| `actual_result` | string | The single evidence entry (from `decision.verdict.evidence`) that describes the actual outcome - matched by field name (`actual_status`, `transport.status`, or `status_code`, the field names this project's producers already render evidence in). Falls back to the first evidence entry if none match. Always a literal evidence entry, never invented text. |
| `reasoning` | string | `decision.verdict.reasoning`, reused verbatim. Never re-summarized or re-generated. |
| `tester_notes` | string | A fixed, per-`status` template (one of four literal strings - see "Tester notes templates" below). Deterministic: the same `status` always produces the same `tester_notes` text. |
| `execution_notes` | string | A deterministic sentence built from `decision.decision_basis` and `decision.decided_at` - e.g. `"Decision reached at 2026-08-02T10:00:00.000Z via a deterministic rule (deterministic_exact_match), no AI call made."` or `"...via an AI-assisted judgment (model: claude-haiku-4-5-20251001, prompt: v1)."`. |
| `confidence` | number | `decision.verdict.confidence`, copied unchanged (`0.0`-`1.0`). |
| `decision_basis` | string | A deterministic rendering of `decision.decision_basis` as `"tier: <tier>[, model: <model_version>][, prompt: <prompt_version>]"` - the object form lives in `decision.decision_basis`; this is its human-readable string form for report display. |
| `manual_review` | boolean | `true` if and only if `decision.verdict.status === 'MANUAL_REVIEW'`. The single field a renderer checks to flag a row for human attention, rather than string-comparing `status` itself. |
| `evidence_summary` | string | `decision.verdict.evidence.join('; ')` - every evidence entry the verdict rests on, concatenated in order. Generated only from the Decision Contract's already-structured evidence array, never re-summarized in prose. |
| `execution_time` | string (ISO 8601) | `decision.decided_at`, copied unchanged. Named for report readability; intentionally the same timestamp as `decision.decided_at`, not a new one - this workflow does not measure or record its own processing time as if it were part of the test's execution. |
| `metadata` | object | `{ documented_at, source_workflow, next_workflow }`. `documented_at` is when this Report Contract instance was produced (the one genuinely new timestamp in this contract - it is a fact about *this* workflow's own run, not about the decision it's documenting). `source_workflow` is always `"05-decision-orchestrator"`. `next_workflow` is `null` - this contract is deliberately terminal with respect to a single named next workflow, since it may be read by zero, one, or several renderer workflows (Excel, PDF, Sheets, dashboard, Jira), not routed to exactly one. |

### Tester notes templates

Exactly four literal strings, selected by `status` alone:

| `status` | `tester_notes` |
|---|---|
| `PASS` | `"No action needed - the actual result satisfied the expected result."` |
| `FAIL` | `"Investigate this failure - the actual result contradicted the expected result."` |
| `BLOCKED` | `"No response was received for this test case. Re-run once the target API/environment is reachable; this is not a statement about the API under test."` |
| `MANUAL_REVIEW` | `"Requires manual review before this verdict is treated as final - confidence fell below the trust threshold, evidence was insufficient, or a hallucination guard rejected part of the automated judgment."` |

## Optional fields

None yet. As with every prior contract in this folder, consumers should
ignore unknown fields rather than fail on them.

---

## Example payloads

**A deterministic PASS:**

```json
{
  "workflow_version": "1.0",
  "report_version": "1.0",
  "test_case": {
    "test_id": "AUTH-022",
    "description": "Verify successful login",
    "expected_result": "200 OK",
    "verification_type": "api"
  },
  "decision": {
    "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
    "response_id": "a2c9e410-9e3b-4f1a-8b2d-3e6f1a7c9d0b",
    "verdict": {
      "status": "PASS",
      "confidence": 1.0,
      "reasoning": "Expected HTTP 200 and received HTTP 200. Deterministic status-code match - no AI evaluation was needed.",
      "evidence": ["status_code: expected 200, actual 200"],
      "next_action": "write_report"
    },
    "decision_basis": {
      "tier": "deterministic_exact_match",
      "model_version": null,
      "prompt_version": null
    },
    "decided_at": "2026-08-02T10:00:00.000Z"
  },
  "report": {
    "status": "PASS",
    "actual_result": "status_code: expected 200, actual 200",
    "reasoning": "Expected HTTP 200 and received HTTP 200. Deterministic status-code match - no AI evaluation was needed.",
    "tester_notes": "No action needed - the actual result satisfied the expected result.",
    "execution_notes": "Decision reached at 2026-08-02T10:00:00.000Z via a deterministic rule (deterministic_exact_match), no AI call made.",
    "confidence": 1.0,
    "decision_basis": "tier: deterministic_exact_match",
    "manual_review": false,
    "evidence_summary": "status_code: expected 200, actual 200",
    "execution_time": "2026-08-02T10:00:00.000Z",
    "metadata": {
      "documented_at": "2026-08-02T10:00:01.200Z",
      "source_workflow": "05-decision-orchestrator",
      "next_workflow": null
    }
  }
}
```

**An AI-assisted MANUAL_REVIEW:**

```json
{
  "workflow_version": "1.0",
  "report_version": "1.0",
  "test_case": {
    "test_id": "PROF-014",
    "description": "Verify profile update returns the updated fields",
    "expected_result": "response should include the updated email and display name",
    "verification_type": "api"
  },
  "decision": {
    "request_id": "b1c2d3e4-5678-4abc-9def-1234567890ab",
    "response_id": "c2d3e4f5-6789-4bcd-8ef0-234567890abc",
    "verdict": {
      "status": "MANUAL_REVIEW",
      "confidence": 0.5,
      "reasoning": "A 200 OK was returned, but the response body is empty, so it cannot be confirmed whether the updated email and display name are actually present as expected_result requires.",
      "evidence": ["actual_status: 200", "response_body: empty"],
      "next_action": "flag_for_review"
    },
    "decision_basis": {
      "tier": "ai_assisted",
      "model_version": "claude-haiku-4-5-20251001",
      "prompt_version": "v1"
    },
    "decided_at": "2026-08-02T10:00:05.400Z"
  },
  "report": {
    "status": "MANUAL_REVIEW",
    "actual_result": "actual_status: 200",
    "reasoning": "A 200 OK was returned, but the response body is empty, so it cannot be confirmed whether the updated email and display name are actually present as expected_result requires.",
    "tester_notes": "Requires manual review before this verdict is treated as final - confidence fell below the trust threshold, evidence was insufficient, or a hallucination guard rejected part of the automated judgment.",
    "execution_notes": "Decision reached at 2026-08-02T10:00:05.400Z via an AI-assisted judgment (model: claude-haiku-4-5-20251001, prompt: v1).",
    "confidence": 0.5,
    "decision_basis": "tier: ai_assisted, model: claude-haiku-4-5-20251001, prompt: v1",
    "manual_review": true,
    "evidence_summary": "actual_status: 200; response_body: empty",
    "execution_time": "2026-08-02T10:00:05.400Z",
    "metadata": {
      "documented_at": "2026-08-02T10:00:06.100Z",
      "source_workflow": "05-decision-orchestrator",
      "next_workflow": null
    }
  }
}
```

(`test_case` shown truncated in both examples for readability - the real
payload carries the full object per `docs/contracts/planner-contract.md`.)

---

## What produces an ERROR instead

Every failure mode this workflow can itself produce becomes the shared
error object (`docs/contracts/error-payload.md`) with
`stage: "documentation_agent"`:

| Failure | `code` | Shipped |
|---|---|---|
| Input isn't a well-formed Decision Contract - missing a required field, `verdict` malformed (invalid status enum, out-of-range confidence, empty evidence), `decision_basis` missing `tier`, or `metadata` missing `decided_at` | `INVALID_DECISION_CONTRACT` | Task 5 |

No retry logic exists here, same as every prior workflow's error path -
each case is validated and reported once.

An upstream ERROR payload (produced by the Decision Orchestrator or
anything earlier) is not re-validated as a Decision Contract - it passes
straight through unchanged, same convention as every prior workflow.

A `MANUAL_REVIEW` report is **not** an error - it is a normal,
successfully-produced Report Contract with `report.manual_review: true`.
This workflow only produces an ERROR payload when it cannot build a
report at all, not when the report it builds documents an uncertain
verdict.

---

## Versioning

Same rules as every prior contract in this folder:

- Bump `report_version` when this contract's *shape* changes (new
  required field, renamed field, changed meaning) - not for new optional
  fields or new error `code` values.
- Bump `workflow_version` when `06-documentation-agent.json`'s internal
  logic changes in a way worth tracking (e.g. a template string changes),
  independent of whether the contract shape changed.

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field.
- Consumers must ignore unknown top-level fields rather than reject them.
- A renderer must treat `report.manual_review` as the single field that
  determines whether a row needs human attention - never re-derive that
  from `report.status` or `report.confidence` directly.
- `report.reasoning`/`report.evidence_summary`/`report.tester_notes`/
  `report.execution_notes` are for human/renderer *display*, never to be
  re-parsed for a routing decision - the same rule the Decision Contract
  states for `verdict.reasoning`/`verdict.evidence`.

## Output independence

This contract, and the workflow that produces it, must never reference a
specific output format - no `excel_row`, `sheet_id`, `pdf_path`,
`dashboard_widget`, or `jira_ticket` field exists anywhere here, and none
should ever be added. A renderer that needs a format-specific value
(e.g. an Excel column mapping, a Jira project key) computes it itself
from this contract's fields, in its own workflow - it never asks this
contract to carry that value for it. This is what keeps the Documentation
Agent reusable across every current and future renderer, per this
document's Purpose section.

## Future extension notes

- A future Excel Writer (Task 5.1), PDF renderer, Google Sheets renderer,
  dashboard consumer, or Jira Agent each reads this same Report Contract
  and adds its own workflow file - none of them is this contract's
  producer, and none requires a change to this document to be built.
- If a renderer needs a value this contract doesn't currently expose, the
  fix is a new field here (additive, following the versioning rules
  above) - never a format-specific field named after the renderer that
  needs it.
- `decision.verdict`/`decision.decision_basis` are carried forward as
  full nested objects (not flattened) specifically so a future consumer
  needing a currently-unused sub-field (e.g. `decision_basis.tier` for
  cost auditing) never requires a Report Contract shape change - it's
  already there.
