# Normalized Response Contract

## Status
Accepted (introduced in Task 3.3)

## Purpose

The payload the Response Normalizer produces from whatever
`03-http-executor` actually returned - a successful HTTP Response
Contract (`docs/contracts/http-response-contract.md`) or an ERROR
payload for a transport failure (timeout, connection refused, DNS
failure, a pre-flight validation error). Both are folded into one stable
shape so the Decision Agent (Task 4, not yet built) never has to branch
on which of the two input shapes it received, never sees which HTTP
client executed the request, and never sees raw n8n/HTTP Request node
internals. This contract is the boundary between *transport* (Tasks
3.1-3.3) and *business logic* (the Decision Agent onward) - it still
makes no PASS/FAIL judgment and calls no AI model.

## Producer

`n8n/workflows/04-response-normalizer.json`

## Consumer

The future Decision Agent workflow (Task 4, not yet built). Until then,
the workflow's terminal `Decision Agent` node is a NoOp hand-off
boundary, the same pattern `03-http-executor.json` uses for its
`Response Normalizer` node.

Not every item this workflow outputs is a Normalized Response Contract -
an input this workflow cannot make sense of at all (a malformed HTTP
Response Contract, a malformed upstream ERROR payload, a status code
outside 100-599, an unrecognized transport error code, or a response
that can't be safely carried through as JSON) produces the shared error
object instead (`docs/contracts/error-payload.md`), exactly as every
prior workflow does. Consumers must check `item.status === 'ERROR'`
before assuming an item is a Normalized Response Contract.

A **transport failure is not one of these cases.** A timeout, a
connection refused, a DNS failure - these are exactly what this workflow
exists to normalize, and they produce a completely ordinary Normalized
Response Contract with `transport.status` set accordingly (`"TIMEOUT"`,
`"NETWORK_ERROR"`, ...), not an ERROR payload. See "Transport status
mapping" below.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`04-response-normalizer.json`), currently `"1.0"`. |
| `contract_version` | string | Version of **this contract's shape**, currently `"1.0"`. Same split rationale as `api-request-contract.md` / `http-response-contract.md`. |
| `request_id` | string \| null | Preserved from the HTTP Response Contract's `request_id`, or from an upstream ERROR payload's `details.request_id` on a transport failure. `null` only if the request_id genuinely could not be determined upstream (e.g. the original API Request Contract itself was invalid before a request_id could be validated). |
| `response_id` | string \| null | Preserved unchanged from the HTTP Response Contract's `response_id` when a real HTTP response was received. **Explicitly `null`** on a transport failure - no response was ever produced, so there is nothing to preserve, and this workflow never invents one. |
| `test_case` | object \| null | Preserved unchanged from the HTTP Response Contract's `test_case`, or from an upstream ERROR payload's `details.test_case`. `null` only if genuinely unavailable upstream. |
| `expected` | object \| null | Preserved unchanged from the HTTP Response Contract's `expected`, or from an upstream ERROR payload's `details.expected`. Never read or compared by this workflow - purely carried forward for the Decision Agent, same as `http-response-contract.md`'s own rationale for carrying it. |
| `transport` | object | `{ status, status_code, response_time_ms }`. `status` is always one of the seven categories in "Transport status mapping" below. `status_code` and `response_time_ms` are `null` on a transport failure (no real response), and the real values on a successful execution. |
| `response` | object | `{ headers, body }`. `headers` is always a plain object (`{}` on a transport failure). `body` is always present as a key - the real body value, or `null` on a transport failure or an absent response body (e.g. `204 No Content`). |
| `metadata` | object | `{ normalized_at, source_workflow, next_workflow }`. `source_workflow` is always `"03-http-executor"` (where the input came from); `next_workflow` is always `"05-decision-agent"` (see the naming-scheme table in `docs/workflow-standards.md`). |

## Optional fields

None yet. As with the other contracts in this folder, consumers should
ignore unknown fields rather than fail on them.

---

## Transport status mapping

Every input - a real HTTP response or a transport-level failure - is
mapped into exactly one of these seven categories. This is the only
vocabulary the Decision Agent ever sees for "what happened at the
transport layer"; it never sees an HTTP client name, an n8n error
message, or a raw status code without this categorization alongside it.

| `transport.status` | Produced when |
|---|---|
| `SUCCESS` | `status_code` is `200`-`299`. |
| `CLIENT_ERROR` | `status_code` is `400`-`499`, excluding `401`/`403` (see `AUTHENTICATION_ERROR`). |
| `SERVER_ERROR` | `status_code` is `500`-`599`. |
| `AUTHENTICATION_ERROR` | `status_code` is `401` or `403`; or the HTTP Executor never sent the request because of `MISSING_CREDENTIALS` or `UNSUPPORTED_AUTHENTICATION`. |
| `NETWORK_ERROR` | The HTTP Executor reported `CONNECTION_REFUSED`, `DNS_RESOLUTION_FAILED`, `NETWORK_ERROR` (its own generic catch-all, which is where an SSL/TLS failure lands - see `docs/reviews/task-3.2-http-executor-review.md` on that classifier's limits), or `INVALID_URL` (the request never reached the network at all). |
| `TIMEOUT` | The HTTP Executor reported `TIMEOUT_ERROR`. |
| `UNKNOWN_ERROR` | Either a valid but uncategorized `status_code` (`1xx`/`3xx` - a real response was received, it just isn't one of the categories above), or the HTTP Executor rejected the request during its own pre-flight validation (`UNSUPPORTED_HTTP_METHOD`, `INVALID_API_REQUEST_CONTRACT`) before any network attempt was made. |

`status_code` and `response_time_ms` inside `transport` are only ever
non-null when a real HTTP response was received (i.e. `transport.status`
came from the status-code branch of the table above, not the
error-code branch) - a transport failure never produces a fabricated
status code or timing value.

The mapping from an HTTP Executor error `code` to a `transport.status`
category lives in `TRANSPORT_CODE_MAP` inside the `Normalize Transport`
node - hand-kept in sync with `03-http-executor.json`'s own error codes
(`docs/contracts/error-payload.md`'s `http_executor` table), the same
convention `01-ingestion.json` uses for `SUPPORTED_VERIFICATION_TYPES` /
`AGENT_ROUTES` (`docs/workflow-standards.md`). An HTTP Executor error
`code` with no entry in that map does **not** silently become
`UNKNOWN_ERROR` - it produces this workflow's own `UNKNOWN_TRANSPORT_ERROR`
(see below), because an unrecognized code from the workflow directly
upstream is a real gap in this mapping table, not a value worth guessing
at.

---

## What produces an ERROR instead

Every failure mode this workflow can itself produce becomes the shared
error object (`docs/contracts/error-payload.md`) with
`stage: "response_normalizer"`:

| Failure | `code` |
|---|---|
| The input is neither a well-formed HTTP Response Contract nor a well-formed upstream ERROR payload (missing required fields, wrong shape) | `INVALID_HTTP_RESPONSE_CONTRACT` |
| The input claims to be a successful HTTP Response Contract, but `status_code` isn't an integer between `100` and `599` | `INVALID_STATUS_CODE` |
| `headers` isn't a JSON object, or `body` can't be safely carried through as JSON (e.g. a circular structure) | `MALFORMED_RESPONSE` |
| An upstream ERROR payload's `code` isn't one of the codes `TRANSPORT_CODE_MAP` knows how to categorize | `UNKNOWN_TRANSPORT_ERROR` |
| Reserved for a defensive catch-all inside `Build Normalized Response Contract` if normalization reaches that node in an unexpected state | `NORMALIZATION_FAILED` |

Every one of these carries `details.request_id` when a request_id was
available, so a failed normalization can still be correlated back to its
originating request even though it never produced a Normalized Response
Contract.

---

## Example payloads

**A successful execution:**

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "response_id": "a2c9e410-9e3b-4f1a-8b2d-3e6f1a7c9d0b",
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "expected_result": "422 Unprocessable Entity",
    "verification_type": "api"
  },
  "expected": { "status": 422, "response": {} },
  "transport": {
    "status": "SUCCESS",
    "status_code": 200,
    "response_time_ms": 184
  },
  "response": {
    "headers": { "content-type": "application/json" },
    "body": { "id": "signup-attempt-12", "created": true }
  },
  "metadata": {
    "normalized_at": "2026-07-29T09:16:00.400Z",
    "source_workflow": "03-http-executor",
    "next_workflow": "05-decision-agent"
  }
}
```

**A timeout** (no HTTP response was ever received - `response_id`,
`transport.status_code`, and `transport.response_time_ms` are explicitly
`null`, not omitted):

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "response_id": null,
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "expected_result": "422 Unprocessable Entity",
    "verification_type": "api"
  },
  "expected": { "status": 422, "response": {} },
  "transport": {
    "status": "TIMEOUT",
    "status_code": null,
    "response_time_ms": null
  },
  "response": {
    "headers": {},
    "body": null
  },
  "metadata": {
    "normalized_at": "2026-07-29T09:16:00.400Z",
    "source_workflow": "03-http-executor",
    "next_workflow": "05-decision-agent"
  }
}
```

(`test_case` shown truncated above for readability - the real payload
carries the full object per `docs/contracts/planner-contract.md`.)

---

## Versioning

Same rules as `docs/contracts/http-response-contract.md`:

- Bump `contract_version` when this contract's *shape* changes (new
  required field, renamed field, changed meaning) - not for new optional
  fields, new error `code` values, or new `TRANSPORT_CODE_MAP` entries.
- Bump `workflow_version` when `04-response-normalizer.json`'s internal
  logic changes in a way worth tracking, independent of whether the
  contract shape changed.

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field - see `docs/contracts/error-payload.md`.
- Consumers must ignore unknown top-level fields rather than reject them.
- Consumers must treat `transport.status` as the only vocabulary for
  "what happened at the transport layer" - never re-derive it from
  `transport.status_code` or infer anything from its being `null`.
- `response.body` is never parsed, reshaped, or validated against
  `expected` by this workflow - that remains the Decision Agent's job
  (docs/architecture/milestone-1.md section 5), same non-goal as
  `03-http-executor.json`.

## Future extension notes

- A future Repository/Database/UI agent (Milestone 2/3) does not consume
  this contract - it's specific to the HTTP execution path. Each
  execution type should get its own normalized contract when it's built,
  not be forced into this one's shape.
- If a later milestone needs to distinguish *which* HTTP Executor error
  code produced a given `NETWORK_ERROR` (e.g. `CONNECTION_REFUSED` vs
  `DNS_RESOLUTION_FAILED` vs `INVALID_URL`), that is additive - a new
  optional field (e.g. `transport.detail_code`) rather than changing what
  `transport.status` means. Milestone 1's Decision Agent does not need
  that distinction (per `docs/architecture/milestone-1.md` section 8, a
  transport failure of any kind maps to a `BLOCKED` verdict), so it is
  deliberately not included yet.
- `TRANSPORT_CODE_MAP` needs a new entry any time `03-http-executor.json`
  introduces a new error `code` - see the note on that map in
  `Normalize Transport`. This is the same hand-kept-in-sync coupling
  flagged in `docs/reviews/task-3.2-http-executor-review.md` for
  `SUPPORTED_METHODS`/`SUPPORTED_AUTH_TYPES`; an unmapped code fails
  loudly (`UNKNOWN_TRANSPORT_ERROR`) rather than silently, but the two
  workflows still need to be updated together.
