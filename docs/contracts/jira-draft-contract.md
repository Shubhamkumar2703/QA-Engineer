# Jira Draft Contract

## Status
Accepted (introduced in Task 6)

## Purpose

The payload the Jira Agent produces after formatting a validated Report
Contract (`docs/contracts/report-contract.md`) into a draft Jira issue.
This is the canonical, not-yet-submitted representation of "what a Jira
ticket for this test case would contain" - it is never created via the
Jira API by the workflow that produces it. The Jira Agent performs
formatting only: every field is either carried forward unchanged from the
Report Contract or derived from it through a fixed, deterministic
template (string concatenation, lookup table, direct re-read of an
already-computed routing decision) - never generated, never AI-authored.

See `docs/architecture/milestone-1.md` section 5's "Jira Agent" row for
the human-approval-gated intent this contract exists to serve, and
`docs/architecture/decisions/005-manual-review-replaces-not-run.md` for
why `MANUAL_REVIEW` (not `NOT_RUN`) is the only other status besides
`FAIL` this contract ever considers drafting for.

## Producer

`n8n/workflows/07-jira-agent.json` (Task 6).

## Consumer

Not yet built: a future duplicate-check integration, human approval
queue, and Jira API submission workflow (Task 6+). This workflow's own
job stops at producing a correct Jira Draft Contract - see "Architecture"
below.

Not every item this workflow outputs is a Jira Draft Contract - an input
this workflow cannot make sense of (a malformed Report Contract, or an
upstream ERROR payload) produces the shared error object instead
(`docs/contracts/error-payload.md`), exactly as every prior workflow
does. Consumers must check `item.status === 'ERROR'` before assuming an
item is a Jira Draft Contract.

---

## Architecture

```
Report Contract
      |
      v
Jira Agent            <- this contract's producer (07-jira-agent.json)
      |
      v
Jira Draft Contract    <- this document
      |
      v
Duplicate Check         <- architecture-only for Milestone 1, no real
      |                    Jira API call yet (see "Extension points")
      v
Draft Ticket           <- not yet built
      |
      v
Human Approval         <- not yet built; a draft never proceeds past
      |                    this point without an explicit approval signal
      v
Create / Update Jira   <- not yet built; the only point a real Jira API
                           call would ever be made
```

Every stage from "Duplicate Check" onward is out of scope for this
document's producer - it exists in `07-jira-agent.json` as a documented
NoOp placeholder, not a functioning integration.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`07-jira-agent.json`), currently `"1.0"`. |
| `jira_version` | string | Version of **this contract's shape**, currently `"1.0"`. Same split rationale as `workflow_version`/`report_version` in the Report Contract - named `jira_version` here for the same reason that document uses `report_version` rather than a generic `contract_version`. |
| `report` | object | The complete, unmodified Report Contract this draft was built from - not a subset. `report.test_case`, `report.decision`, and `report.report` all remain reachable, so a draft (or a rejected/approved one, later) can always be traced back to the exact decision and test case it came from without re-fetching anything. |
| `jira` | object | The draft fields themselves - see "jira" below. This is the only object this workflow actually *builds*; `report` is carried forward unchanged. |

### `jira` object

| Field | Type | Description |
|---|---|---|
| `required` | boolean | `true` only when `report.report.status === 'FAIL'`, or when it is `'MANUAL_REVIEW'` **and** the Jira Agent's `DRAFT_ON_MANUAL_REVIEW` configuration flag is enabled (off by default - see "MANUAL_REVIEW is configurable" below). Always `false` for `PASS` and `BLOCKED`. |
| `summary` | string \| null | `"<status>: <test_case.description>"` (e.g. `"FAIL: Verify password length validation"`) when `required` is `true`; `null` otherwise. |
| `description` | string \| null | `report.report.reasoning`, reused verbatim, when `required` is `true`; `null` otherwise. Never re-summarized. |
| `expected_result` | string \| null | `report.test_case.expected_result`, reused verbatim, when `required` is `true`; `null` otherwise. |
| `actual_result` | string \| null | `report.report.actual_result`, reused verbatim, when `required` is `true`; `null` otherwise. |
| `reproduction_steps` | string \| null | `report.test_case.steps`, reused verbatim, when `required` is `true`; `null` otherwise. The original test's own steps - never re-authored. |
| `evidence` | array of strings | `report.decision.verdict.evidence`, reused verbatim (the same structured array the Decision Contract's verdict rested on), when `required` is `true`; empty array otherwise. |
| `priority` | string \| null | `"High"` when `report.decision.verdict.next_action === 'create_jira'`; `"Medium"` when it is `'flag_for_review'`; `null` when `required` is `false`. Deliberately re-reads `next_action` rather than re-deriving a confidence threshold - see "Priority reuses next_action" below. |
| `labels` | array of strings | `["ai-detected"]` plus `"needs-triage"` for `FAIL`, or plus `"manual-review"` for `MANUAL_REVIEW`, when `required` is `true`; empty array otherwise. |
| `components` | array of strings | Looked up from `report.test_case.verification_type` (Milestone 1: `"api"` → `["API"]`) when `required` is `true`; empty array otherwise. An unrecognized `verification_type` produces an empty array, never a fabricated component. |
| `manual_review` | boolean | `report.report.manual_review`, copied unchanged - present regardless of `required`, so a consumer can always tell a `MANUAL_REVIEW` report apart from a `FAIL` even when no draft was built for it. |

## Optional fields

None yet. As with every prior contract in this folder, consumers should
ignore unknown fields rather than fail on them.

---

## When a draft is required

| `report.report.status` | `jira.required` |
|---|---|
| `PASS` | `false`, always |
| `BLOCKED` | `false`, always |
| `FAIL` | `true`, always |
| `MANUAL_REVIEW` | `false` by default; `true` only if `DRAFT_ON_MANUAL_REVIEW` is enabled (see below) |

### MANUAL_REVIEW is configurable

`DRAFT_ON_MANUAL_REVIEW` is a single named constant at the top of
`07-jira-agent.json`'s `Build Jira Draft Contract` node, `false` by
default. Milestone 1 does not draft a ticket for a case a human still
needs to review the *verdict* of, only for one the pipeline is confident
enough to call a real defect (`FAIL`) - flipping the constant to `true`
is a one-line, single-place change, not a workflow redesign, for a future
milestone that wants `MANUAL_REVIEW` cases drafted too.

### Priority reuses `next_action`

`priority` never re-derives a confidence threshold of its own. It reads
`report.decision.verdict.next_action` directly - a field
`05-decision-orchestrator.json`'s Apply Trust Rules already computed from
confidence (`create_jira` only for a `FAIL` at or above the
auto-Jira confidence threshold, `flag_for_review` for everything else
that still needs a human) - and maps it to a Jira priority:
`create_jira` → `High`, `flag_for_review` → `Medium`. This follows
`docs/workflow-standards.md`'s "nothing downstream re-derives a value
another workflow already computed" rule.

---

## Example payloads

**A FAIL (draft required, high confidence):**

```json
{
  "workflow_version": "1.0",
  "jira_version": "1.0",
  "report": {
    "workflow_version": "1.0",
    "report_version": "1.0",
    "test_case": {
      "test_id": "AUTH-021",
      "description": "Verify password length validation",
      "expected_result": "422 Unprocessable Entity",
      "steps": "1. POST /signup with a 5-character password",
      "verification_type": "api"
    },
    "decision": {
      "request_id": "b1c2d3e4-5678-4abc-9def-1234567890ab",
      "response_id": "c2d3e4f5-6789-4bcd-8ef0-234567890abc",
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
      "decided_at": "2026-08-02T10:00:05.400Z"
    },
    "report": {
      "status": "FAIL",
      "actual_result": "actual_status: 200",
      "reasoning": "Expected 422 Unprocessable Entity for a 5-character password; API returned 200 OK and created the account.",
      "tester_notes": "Investigate this failure - the actual result contradicted the expected result.",
      "execution_notes": "Decision reached at 2026-08-02T10:00:05.400Z via an AI-assisted judgment (model: claude-haiku-4-5-20251001, prompt: v1).",
      "confidence": 0.95,
      "decision_basis": "tier: ai_assisted, model: claude-haiku-4-5-20251001, prompt: v1",
      "manual_review": false,
      "evidence_summary": "expected_status: 422; actual_status: 200; response_body.created: true",
      "execution_time": "2026-08-02T10:00:05.400Z",
      "metadata": {
        "documented_at": "2026-08-02T10:00:06.100Z",
        "source_workflow": "05-decision-orchestrator",
        "next_workflow": null
      }
    }
  },
  "jira": {
    "required": true,
    "summary": "FAIL: Verify password length validation",
    "description": "Expected 422 Unprocessable Entity for a 5-character password; API returned 200 OK and created the account.",
    "expected_result": "422 Unprocessable Entity",
    "actual_result": "actual_status: 200",
    "reproduction_steps": "1. POST /signup with a 5-character password",
    "evidence": ["expected_status: 422", "actual_status: 200", "response_body.created: true"],
    "priority": "High",
    "labels": ["ai-detected", "needs-triage"],
    "components": ["API"],
    "manual_review": false
  }
}
```

**A PASS (no draft required):**

```json
{
  "workflow_version": "1.0",
  "jira_version": "1.0",
  "report": { "...": "full Report Contract, status PASS, omitted here for brevity" },
  "jira": {
    "required": false,
    "summary": null,
    "description": null,
    "expected_result": null,
    "actual_result": null,
    "reproduction_steps": null,
    "evidence": [],
    "priority": null,
    "labels": [],
    "components": [],
    "manual_review": false
  }
}
```

(`report` shown truncated in the second example for readability - the
real payload always carries the full object, per every prior contract in
this folder's convention.)

---

## Extension points

Milestone 1 builds this contract's producer only up through "Jira Draft
Contract" in the architecture diagram above. The following are
deliberately unimplemented, documented extension points, not omissions:

- **Duplicate Check.** `07-jira-agent.json`'s `Duplicate Check (Extension
  Point)` node is a NoOp that passes every Jira Draft Contract through
  unchanged. A future implementation queries the Jira API for an existing
  open issue labeled with `report.test_case.test_id`; if found, it would
  add a field (e.g. `jira.duplicate_of`) to this contract - additive, not
  a redesign - and "Draft Ticket" would add a comment to that issue
  instead of drafting a new one, per
  `docs/architecture/milestone-1.md` section 5's Jira Agent row.
- **Draft Ticket / Human Approval / Create / Update Jira.** Each is a
  documented NoOp hand-off in `07-jira-agent.json`. No Jira API call
  exists anywhere in this task's scope - Milestone 1's human-gate
  requirement ("Do not automatically create Jira issues") means a draft
  only ever proceeds past Human Approval on an explicit approval signal,
  not built here.

---

## What produces an ERROR instead

Every failure mode this workflow can itself produce becomes the shared
error object (`docs/contracts/error-payload.md`) with
`stage: "jira_agent"`:

| Failure | `code` | Shipped |
|---|---|---|
| Input isn't a well-formed Report Contract - missing a required field, `test_case` missing `test_id`/`description`/`expected_result`/`steps`/`verification_type`, `report` malformed (invalid status enum, non-string `actual_result`/`reasoning`, non-boolean `manual_review`), or `decision.verdict` missing a non-empty `evidence` array / `next_action` | `INVALID_REPORT_CONTRACT` | Task 6 |

No retry logic exists here, same as every prior workflow's error path.

An upstream ERROR payload (produced by the Documentation Agent, Excel
Writer, or anything earlier) is not re-validated as a Report Contract -
it passes straight through unchanged, same convention as every prior
workflow.

A Jira Draft Contract with `jira.required: false` is **not** an error -
it is the normal, successfully-produced outcome for `PASS`, `BLOCKED`,
and (by default) `MANUAL_REVIEW`. This workflow only produces an ERROR
payload when it cannot build a Jira Draft Contract at all, not when the
contract it builds correctly says no ticket is needed.

---

## Versioning

Same rules as every prior contract in this folder:

- Bump `jira_version` when this contract's *shape* changes (new required
  field, renamed field, changed meaning) - not for new optional fields or
  new error `code` values.
- Bump `workflow_version` when `07-jira-agent.json`'s internal logic
  changes in a way worth tracking (e.g. a label/priority template
  changes), independent of whether the contract shape changed.

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field.
- Consumers must ignore unknown top-level fields rather than reject them.
- A future Duplicate Check / approval consumer must treat `jira.required`
  as the single field that determines whether a draft needs review at
  all - never re-derive that from `report.report.status` directly.
- `jira.description`/`jira.evidence` are for human/Jira display, never to
  be re-parsed for a routing decision - the same rule the Decision
  Contract and Report Contract state for their own reasoning/evidence
  fields.

## Future extension notes

- A future Duplicate Check implementation adds a field to `jira` (e.g.
  `duplicate_of`) - additive, per the versioning rules above - never a
  reshaping of the fields this document already defines.
- If `DRAFT_ON_MANUAL_REVIEW` is ever turned on, no contract shape change
  is required - `jira.required` simply becomes `true` more often, and
  every other field is already defined for that case.
- `report` is carried forward as the complete Report Contract (not
  flattened) specifically so a future consumer needing a currently-unused
  sub-field (e.g. `report.decision.decision_basis.model_version` for
  cost auditing on drafted tickets) never requires a Jira Draft Contract
  shape change - it's already there.
