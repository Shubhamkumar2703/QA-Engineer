# Shared Error Payload

## Status
Accepted (introduced in Task 2.5)

## Purpose

A single, reusable shape for "something about this item is wrong" that
every workflow returns instead of a routing contract or agent-specific
output. It exists so downstream nodes and future workflows can detect and
handle a failure with one check (`item.status === 'ERROR'`) instead of
each workflow inventing its own error shape. This is the concrete
implementation of the Milestone 1 rule "fail loudly instead of silently"
(`CLAUDE.md`, `docs/architecture/milestone-1.md` section 8) at the data
level: a bad row doesn't get silently dropped or crash the whole batch, it
comes out the other end as a clearly-marked, inspectable object.

This is distinct from n8n's own node-execution error handling (a node
throwing and stopping the workflow). This object is for **data-quality /
validation failures that are expected to happen** (a malformed Excel row,
an unsupported value) and that a batch of otherwise-valid items should
survive - each test case is processed independently, so one bad row must
not take the rest of the run down with it.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `status` | string | Always the literal `"ERROR"`. This is the field every consumer checks first. |
| `stage` | string | Which workflow/stage produced the error, e.g. `"ingestion"`, `"planner_routing"`, `"api_agent"`. Snake_case, matches the stage's role, not its file name. |
| `code` | string | SCREAMING_SNAKE_CASE, stable machine-readable error code. Never changes wording for the same underlying condition - `message` is for humans, `code` is for programs (and eventually for grouping/counting errors). |
| `message` | string | Human-readable explanation, specific enough to act on. Follows the Playbook's "Error Handling" standard: say what failed and why, not just that something failed. |
| `details` | object | Structured context for this specific error (e.g. `source_file`, `row_number`, the offending value). Empty object (`{}`) if there's nothing beyond the message. Never put a full stack trace or secret values here. |
| `timestamp` | string (ISO 8601) | When the error was produced. |
| `workflow_version` | string | Version of the workflow that produced the error (same versioning rules as `docs/contracts/planner-contract.md`). |

## Optional fields

None currently reserved. If a future workflow needs to attach something
error-specific that doesn't fit `details`, it should still fit inside
`details` rather than adding a new top-level field - keep the outer shape
identical across every workflow so a generic error handler never needs to
special-case a producer.

---

## Example payload

```json
{
  "status": "ERROR",
  "stage": "ingestion",
  "code": "MISSING_REQUIRED_FIELD",
  "message": "Row 3 in missing-column.xlsx is missing required field(s): expected_result",
  "details": {
    "source_file": "missing-column.xlsx",
    "row_number": 3,
    "missing_fields": ["expected_result"]
  },
  "timestamp": "2026-07-29T09:15:00.000Z",
  "workflow_version": "1.0"
}
```

## Error codes currently in use (ingestion workflow)

| Code | Stage | Meaning |
|---|---|---|
| `MISSING_REQUIRED_FIELD` | `ingestion` | One or more required Excel columns were blank or absent for this row. |
| `UNSUPPORTED_VERIFICATION_TYPE` | `ingestion` | `verification_type` isn't one Milestone 1 supports (currently only `api`). |
| `DUPLICATE_TEST_ID` | `ingestion` | The same `test_id` appears more than once in the source file. |
| `NO_ROUTE_FOR_VERIFICATION_TYPE` | `planner_routing` | Safety-net check in case a `verification_type` passes ingestion validation but has no entry in the routing table - should not normally trigger while `SUPPORTED_VERIFICATION_TYPES` and `AGENT_ROUTES` are kept in sync (see `docs/workflow-standards.md`). |

## Error codes currently in use (HTTP Executor workflow, `stage: "http_executor"`)

| Code | Meaning |
|---|---|
| `INVALID_API_REQUEST_CONTRACT` | The incoming item isn't a well-formed API Request Contract (docs/contracts/api-request-contract.md) - missing a required field, or a field has the wrong shape. |
| `UNSUPPORTED_HTTP_METHOD` | `method` isn't one of `GET`/`POST`/`PUT`/`PATCH`/`DELETE`. Re-checked independently of the API Request Builder's own validation. |
| `INVALID_URL` | `url` doesn't parse as a URL, or its protocol isn't `http`/`https`. |
| `UNSUPPORTED_AUTHENTICATION` | `authentication.type` isn't one of `none`/`bearer`/`api_key`. |
| `MISSING_CREDENTIALS` | A `bearer`/`api_key` authentication type was requested but the HTTP Executor's own environment doesn't have the corresponding credential (`API_AUTH_BEARER_TOKEN` / `API_AUTH_API_KEY_VALUE`) configured. |
| `TIMEOUT_ERROR` | The request did not complete within the contract's `timeout`. |
| `CONNECTION_REFUSED` | The target host actively refused the connection. |
| `DNS_RESOLUTION_FAILED` | The target host name could not be resolved. |
| `NETWORK_ERROR` | Any other network-level failure that isn't one of the above - a catch-all so a failure is never silently dropped even if its exact cause can't be classified. |

A non-2xx/3xx HTTP status code returned by the target API (e.g. `404`,
`500`) is **not** an error under this contract - it is a normal
`status_code` value on the HTTP Response Contract
(docs/contracts/http-response-contract.md). The HTTP Executor has no
opinion on whether a status code represents a pass or a fail.

New workflows should add their own codes to this table when they introduce
one, rather than reusing an existing code for a different condition.

---

## Versioning rules

Same rules as `docs/contracts/planner-contract.md`: `workflow_version`
identifies the producing workflow's own version, bump it on shape changes
to this object, not on new `code` values (adding a new `code` is additive
and doesn't require a version bump).

## Future compatibility notes

- Every future workflow (API Agent, Decision Agent, Documentation Agent,
  Jira Agent) reuses this exact shape for its own validation/data-quality
  failures. Do not invent a workflow-specific error shape - extend
  `details` and add a new `code` to that workflow's section of this table
  instead.
- This object is intentionally not tied to n8n's built-in error-workflow
  mechanism. Nothing here prevents also wiring n8n's error trigger for
  genuine node crashes later - that is a separate, orthogonal concern from
  this data-level contract.
