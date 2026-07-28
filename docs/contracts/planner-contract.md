# Planner Routing Contract

## Status
Accepted (introduced in Task 2.5)

## Purpose

This is the payload every ingestion-side workflow hands to the Planner, and
the shape every future agent workflow (API Agent, Repository Agent,
Database Agent, UI Agent) can expect to receive from the Planner. It exists
so that adding a new `verification_type` / agent in a later milestone means
adding a routing entry, not reshaping every downstream workflow's input
parsing.

This is a superset of the Test Case JSON schema defined in
`docs/architecture/milestone-1.md` section 7. Milestone 1 documentation
remains the source of truth for the core test case fields; this document
only adds the routing envelope around it and the ingestion-metadata fields
listed below. It does not change or override the milestone's scope.

Not every item leaving ingestion is a routing contract. A row that fails
validation produces the shared error object instead
(`docs/contracts/error-payload.md`) so downstream nodes can tell the two
apart with a single check: `item.status === 'ERROR'`.

---

## Required fields (envelope)

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the *ingestion workflow* that produced this contract (currently `"1.0"`). Not a whole-system version - see Versioning rules below. |
| `ingestion_timestamp` | string (ISO 8601) | When this test case was normalized by ingestion. |
| `agent` | string | Which agent type should handle this test case. Milestone 1 only ever emits `"api"`. |
| `verification_type` | string | Copied from `test_case.verification_type`, surfaced at the top level so routing can happen without unwrapping `test_case`. |
| `next_node` | string | The exact node/workflow name the receiving system should hand this to next. Milestone 1 only ever emits `"API Agent"`. |
| `test_case` | object | The full Test Case JSON object - see below. |

## Optional fields

None yet. `agent` / `next_node` are currently a fixed pair
(`api` / `"API Agent"`) because Milestone 1 only implements the API route.
Later milestones may add optional routing fields (e.g. a list of secondary
agents) without breaking this contract, since consumers should ignore
unknown fields rather than fail on them.

---

## `test_case` object

Every field from `docs/architecture/milestone-1.md` section 7, plus three
ingestion-metadata fields required by Task 2.5:

| Field | Type | Notes |
|---|---|---|
| `source_file` | string | Base filename of the Excel workbook this row came from. |
| `row_number` | number | 1-indexed row number in that workbook (header is row 1, so the first data row is `2`). Reflects the row's real position in the source file, independent of how many other rows were dropped or errored. |
| `ingestion_timestamp` | string (ISO 8601) | Same value as the envelope's `ingestion_timestamp`, kept on `test_case` too so the object is self-describing if it's ever logged or stored on its own. |

All other `test_case` fields follow the milestone-1 schema exactly. Fields
a later agent hasn't run yet stay `null` - ingestion never invents a value
for a field it doesn't own.

---

## Example payload

```json
{
  "workflow_version": "1.0",
  "ingestion_timestamp": "2026-07-29T09:15:00.000Z",
  "agent": "api",
  "verification_type": "api",
  "next_node": "API Agent",
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "steps": "POST /signup with a 5-character password",
    "expected_result": "422 Unprocessable Entity",
    "actual_result": null,
    "status": null,
    "confidence": null,
    "evidence": null,
    "next_action": null,
    "verification_type": "api",
    "tester": "AI-Agent",
    "date": null,
    "notes": null,
    "agent_reasoning": null,
    "jira_key": null,
    "run_id": "1234",
    "workflow_version": "1.0",
    "prompt_version": null,
    "model_version": null,
    "repo_commit": null,
    "timestamp": "2026-07-29T09:15:00.000Z",
    "human_verdict": null,
    "source_file": "sample-api-tests.xlsx",
    "row_number": 2,
    "ingestion_timestamp": "2026-07-29T09:15:00.000Z"
  }
}
```

---

## Versioning rules

- `workflow_version` on this contract identifies the version of the
  **ingestion workflow** (`n8n/workflows/01-ingestion.json`) that produced
  it - not a whole-system/pipeline version. Ingestion is the only workflow
  that exists so far; once API Agent, Decision Agent, etc. exist, revisit
  whether a separate system-wide run version is needed (it would live
  alongside, not replace, this field).
- Bump `workflow_version` (`"1.0"` -> `"1.1"`, `"2.0"`, ...) whenever the
  *shape* of this contract changes - new required field, renamed field,
  changed meaning of an existing field. Do not bump it for changes that
  only affect values (e.g. a new supported `verification_type`).
- Follow semantic-version-style judgment: additive, backward-compatible
  changes (new optional field) bump the minor version; breaking changes
  (removed/renamed required field) bump the major version.
- Never edit this document's "Example payload" in place when the contract
  changes shape - update it alongside the version bump so the example
  always matches the current version, and call out the change in the
  ADR/decision log if it's a breaking change.

## Future compatibility notes

- Adding a new agent (Repository, Database, UI in Milestone 2/3) means
  adding an entry to the `AGENT_ROUTES` map inside the
  `Build Planner Routing Contract` node in `01-ingestion.json` (and the
  matching `SUPPORTED_VERIFICATION_TYPES` entry in
  `Normalize To Test Case JSON` in the same workflow) - not changing this
  document's envelope shape or any existing consumer.
- Consumers (API Agent and later agents) should always branch on
  `next_node` / `agent`, never assume `test_case` only ever has an `api`
  shape.
- Consumers should check `item.status === 'ERROR'` before assuming an item
  is a routing contract - see `docs/contracts/error-payload.md`.
