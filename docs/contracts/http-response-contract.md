# HTTP Response Contract

## Status
Accepted (introduced in Task 3.2)

## Purpose

The payload the HTTP Executor produces after executing an API Request
Contract (`docs/contracts/api-request-contract.md`). It fully describes
what actually happened when the request was sent - status code, response
headers/body, latency, and timestamps - without judging whether that
result is a PASS or a FAIL. That judgment belongs to the future Decision
Agent; this contract only reports facts.

## Producer

`n8n/workflows/03-http-executor.json`

## Consumer

The future Response Normalizer workflow (Task 3.3, not yet built). Until
then, the workflow's terminal `Response Normalizer` node is a NoOp
hand-off boundary, the same pattern `02-api-request-builder.json` uses for
its `HTTP Executor` node.

Not every item this workflow outputs is an HTTP Response Contract - a
request that fails contract validation, fails URL/method validation, or
fails at the network level (timeout, connection refused, DNS failure)
produces the shared error object instead
(`docs/contracts/error-payload.md`), exactly as every prior workflow does.
Consumers must check `item.status === 'ERROR'` before assuming an item is
a response contract.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`03-http-executor.json`), currently `"1.0"`. |
| `contract_version` | string | Version of **this contract's shape**, currently `"1.0"`. Same split rationale as `api-request-contract.md`. |
| `request_id` | string (UUID v4) | Copied unchanged from the API Request Contract that produced this response - the join key back to the original request. Never regenerated. |
| `response_id` | string (UUID v4) | Unique per executed response. Lets a single request be retried without losing correlation with a specific attempt's response. |
| `status_code` | number | The HTTP status code returned by the target API (e.g. `200`, `404`, `500`). Always present when the request executed - see "What produces an ERROR instead" below for when it isn't. |
| `status_text` | string \| null | The HTTP status message (e.g. `"OK"`, `"Not Found"`), when the target API/HTTP client provides one. `null` if unavailable. |
| `headers` | object | Response headers, exactly as returned by the target API. |
| `body` | any \| null | Response body. Whatever shape the target API returned (object, array, string) - this workflow does not parse, reshape, or validate it. `null` if the response had no body (e.g. `204 No Content`). |
| `latency_ms` | number | Wall-clock milliseconds between sending the request and receiving the response, measured by this workflow. |
| `timestamps` | object | `{ sent_at, received_at }`, both ISO 8601. |
| `request` | object | `{ method, url }` - a minimal echo of what was actually sent, for a human or the Decision Agent to read without re-opening the original API Request Contract. |
| `expected` | object | Carried forward unchanged from the API Request Contract's `expected` field. This workflow never reads or compares it - it is passed through so the Decision Agent doesn't need to separately fetch the original request contract to know what was expected. |
| `test_case` | object | Carried forward unchanged from the API Request Contract's `test_case` field, for the same reason `api-request-contract.md` embeds it: a human debugging a failed run, or the future Decision Agent, needs the original description/expected_result without joining across contracts. |
| `metadata` | object | `{ created_at, source_workflow, next_workflow }`. `source_workflow` is always `"03-http-executor"`; `next_workflow` is always `"04-response-normalizer"` (see the naming-scheme table in `docs/workflow-standards.md`). |

## Optional fields

None yet. As with the other contracts in this folder, consumers should
ignore unknown fields rather than fail on them.

---

## What produces an ERROR instead

This workflow never throws away a failure silently - every failure mode
becomes the shared error object (`docs/contracts/error-payload.md`) with
`stage: "http_executor"`:

| Failure | `code` |
|---|---|
| API Request Contract is missing a required field, or a field has the wrong shape | `INVALID_API_REQUEST_CONTRACT` |
| `method` isn't one of `GET`/`POST`/`PUT`/`PATCH`/`DELETE` | `UNSUPPORTED_HTTP_METHOD` |
| `url` doesn't parse, or isn't `http`/`https` | `INVALID_URL` |
| `authentication.type` isn't one of `none`/`bearer`/`api_key` | `UNSUPPORTED_AUTHENTICATION` |
| A `bearer`/`api_key` auth type is requested but this workflow's environment doesn't have the credential configured | `MISSING_CREDENTIALS` |
| The request timed out | `TIMEOUT_ERROR` |
| The target refused the connection | `CONNECTION_REFUSED` |
| The target host couldn't be resolved | `DNS_RESOLUTION_FAILED` |
| Any other network-level failure | `NETWORK_ERROR` |

Every one of these carries `details.request_id` (when a request_id was
available) so a failed execution can still be correlated back to its
originating API Request Contract even though it never produced a response
contract.

A non-2xx/3xx HTTP status returned by the target API (`400`, `404`,
`500`, ...) is **not** one of these failures - it is a completely normal
`status_code` value on a regular HTTP Response Contract. This workflow
has no opinion on whether a given status code represents a passing or
failing test; only the Decision Agent does.

---

## Example payload

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "response_id": "a2c9e410-9e3b-4f1a-8b2d-3e6f1a7c9d0b",
  "status_code": 200,
  "status_text": "OK",
  "headers": { "content-type": "application/json" },
  "body": { "id": "signup-attempt-12", "created": true },
  "latency_ms": 184,
  "timestamps": {
    "sent_at": "2026-07-29T09:16:00.100Z",
    "received_at": "2026-07-29T09:16:00.284Z"
  },
  "request": {
    "method": "POST",
    "url": "https://api.example-test-target.com/signup"
  },
  "expected": { "status": 422, "response": {} },
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "expected_result": "422 Unprocessable Entity",
    "verification_type": "api"
  },
  "metadata": {
    "created_at": "2026-07-29T09:16:00.284Z",
    "source_workflow": "03-http-executor",
    "next_workflow": "04-response-normalizer"
  }
}
```

(`test_case` shown truncated above for readability - the real payload
carries the full object per `docs/contracts/planner-contract.md`.)

---

## Authentication

Per `docs/contracts/api-request-contract.md`, the API Request Contract's
`authentication` field only ever carries a strategy marker
(`{ type, credentials: { strategy, resolved_by: "http_executor" } }`),
never a real secret. This workflow is the `http_executor` that promise
refers to: for `type: "bearer"` it reads `API_AUTH_BEARER_TOKEN` from its
own environment and sets an `Authorization: Bearer <token>` header; for
`type: "api_key"` it reads `API_AUTH_API_KEY_HEADER` (defaults to
`X-API-Key`) and `API_AUTH_API_KEY_VALUE`. If the required environment
variable isn't set, the request is never sent - the workflow returns
`MISSING_CREDENTIALS` instead. Per ADR 002, these are placeholder
environment variables for Milestone 1's single test target; a future
milestone with multiple targets/credentials would revisit this as n8n
native credentials rather than plain environment variables.

---

## Versioning

Same rules as `docs/contracts/api-request-contract.md`:

- Bump `contract_version` when this contract's *shape* changes (new
  required field, renamed field, changed meaning) - not for new optional
  fields or new error `code` values.
- Bump `workflow_version` when `03-http-executor.json`'s internal logic
  changes in a way worth tracking, independent of whether the contract
  shape changed.

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field - see `docs/contracts/error-payload.md`.
- Consumers must ignore unknown top-level fields rather than reject them.
- `body` is never parsed, reshaped, normalized, or validated against
  `expected` by this workflow - that is explicitly out of scope for Task
  3.2 and belongs to the Response Normalizer (Task 3.3) and Decision
  Agent respectively.

## Future extension notes

- A future Repository/Database/UI agent (Milestone 2/3) does not consume
  this contract - it's specific to the HTTP execution path. Each
  execution type should get its own response contract when it's built,
  not be forced into this one's shape.
- If a later milestone needs retry attempts recorded, add an `attempt`
  field rather than changing what a single response means - this
  contract deliberately describes one executed attempt, not a request's
  full retry history.
