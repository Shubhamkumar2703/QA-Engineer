# API Request Contract

## Status
Accepted (introduced in Task 3.1)

## Purpose

The payload the API Request Builder produces from a valid Planner Contract
(`docs/contracts/planner-contract.md`). It fully describes an HTTP request
that could be sent - method, URL, headers, query, body, auth strategy,
timeout, and what response is expected - without actually sending it. This
is what lets request *preparation* (Task 3.1, this document) stay a
separate, independently testable concern from request *execution*
(Task 3.2, the HTTP Executor - not built yet).

## Producer

`n8n/workflows/02-api-request-builder.json`

## Consumer

The future HTTP Executor workflow (Task 3.2). Not built yet - this
contract is the interface it will consume once it exists. Until then, the
workflow's terminal `HTTP Executor` node is a NoOp hand-off boundary, the
same pattern `01-ingestion.json` uses for its `Planner` node.

Not every item this workflow outputs is an API Request Contract - a row
that fails validation produces the shared error object instead
(`docs/contracts/error-payload.md`), exactly as ingestion does. Consumers
must check `item.status === 'ERROR'` before assuming an item is a request
contract.

---

## Required fields

| Field | Type | Description |
|---|---|---|
| `workflow_version` | string | Version of the **producing workflow** (`02-api-request-builder.json`), currently `"1.0"`. Same meaning as `workflow_version` in `planner-contract.md` - the workflow's own version, not a whole-system version. |
| `contract_version` | string | Version of **this contract's shape**, currently `"1.0"`. Kept separate from `workflow_version` so the builder's internal logic can change without the contract shape changing, and vice versa - see Versioning rules below. |
| `request_id` | string (UUID v4) | Unique per built request. Lets a single test case be retried or re-built without losing correlation with the original attempt, and gives the HTTP Executor and any future logging a stable join key. |
| `method` | string | One of `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. |
| `base_url` | string | The target API's base URL, from the `SWAGGER_BASE_URL` environment variable. |
| `path` | string | The endpoint path, e.g. `/signup`. |
| `url` | string | `base_url` + `path`, already joined. Convenience field so a consumer never has to concatenate them itself. |
| `headers` | object | Request headers. Always includes `Content-Type: application/json` for now; never contains a real credential (see Authentication structure below). |
| `query` | object | Query parameters. `{}` unless the test case carries an explicit `query` object. |
| `body` | object \| null | Request body. `null` for `GET`/`DELETE`. `{}` (or the test case's explicit `request_body`) for `POST`/`PUT`/`PATCH`. |
| `authentication` | object | See Authentication structure below. |
| `timeout` | number | Milliseconds. Defaults to `30000`; overridable via `API_REQUEST_TIMEOUT_MS`. |
| `expected` | object | `{ status: number \| null, response: {} }`. `status` is a best-effort parse of a leading 3-digit code in `test_case.expected_result` (e.g. `"422 Unprocessable Entity"` → `422`); `null` if it can't be parsed. Never blocks the build. `response` is always `{}` - Milestone 1 has no structured expected-response schema yet. |
| `test_case` | object | The full Test Case JSON object this request was built from (`docs/contracts/planner-contract.md`). Not in the task's suggested schema, added here deliberately - see "Compatibility rules" below. |
| `metadata` | object | `{ created_at, source_workflow, next_workflow }`. `source_workflow` is always `"01-ingestion"` (where the Planner Contract came from); `next_workflow` is always `"03-http-executor"` (see the naming-scheme note in `docs/workflow-standards.md`). |

## Optional fields

None yet. As with `planner-contract.md`, consumers should ignore unknown
fields rather than fail on them, so future optional fields (e.g. retry
hints for the HTTP Executor) can be added without a version bump.

---

## Authentication structure

```json
{
  "type": "none | bearer | api_key",
  "credentials": null
}
```

- `type` is the resolved authentication **strategy** - never a live
  credential.
- `credentials` is always `null` for `type: "none"`. For `bearer` or
  `api_key`, it is `{ "strategy": "<type>", "resolved_by": "http_executor" }`
  - a marker, not a secret.
- This workflow deliberately never reads or embeds a real token/API key.
  Doing so would put a plaintext credential into n8n execution data
  (visible in the UI, potentially logged or persisted) just to describe
  intent. Per ADR 002, real credentials belong in n8n's own encrypted
  credential store. Whichever workflow actually executes the HTTP call is
  responsible for attaching a real credential at execution time - this
  contract only tells it which strategy to use.
- Supported `type` values for Milestone 1: `none`, `bearer`, `api_key`.
  An unsupported value (e.g. `oauth2`) produces `UNSUPPORTED_AUTHENTICATION`
  (`docs/contracts/error-payload.md`).

---

## Example payload

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "method": "POST",
  "base_url": "https://api.example-test-target.com",
  "path": "/signup",
  "url": "https://api.example-test-target.com/signup",
  "headers": { "Content-Type": "application/json" },
  "query": {},
  "body": {},
  "authentication": { "type": "none", "credentials": null },
  "timeout": 30000,
  "expected": { "status": 422, "response": {} },
  "test_case": {
    "test_id": "AUTH-021",
    "description": "Verify password length validation",
    "steps": "POST /signup with a 5-character password",
    "expected_result": "422 Unprocessable Entity",
    "verification_type": "api"
  },
  "metadata": {
    "created_at": "2026-07-29T09:16:00.000Z",
    "source_workflow": "01-ingestion",
    "next_workflow": "03-http-executor"
  }
}
```

(`test_case` shown truncated above for readability - the real payload
carries the full object per `docs/contracts/planner-contract.md`.)

---

## How method + endpoint are resolved

Milestone 1's Excel schema (`docs/architecture/milestone-1.md` section 7)
does not have separate `method`/`endpoint` columns - the only place this
information exists today is `test_case.steps`, written as free text (e.g.
`"POST /signup with a 5-character password"`). This is not new: it is the
exact phrasing used in the worked example in `docs/architecture/milestone-1.md`
section 6.

The API Request Builder resolves method and endpoint with a fixed,
deterministic rule - **no AI, no inference beyond pattern matching**:

1. If `test_case.method` is present, use it as the method.
2. If `test_case.endpoint` (or `.path`) is present, use it as the path.
3. For whichever of the two is still missing, parse the leading
   `<TOKEN> /<path>` pattern from `test_case.steps` (first whitespace-
   separated token, then a token starting with `/`).
4. If a path still can't be determined → `INVALID_ENDPOINT`.
5. If a method still can't be determined → `MISSING_REQUIRED_FIELD`
   (`missing_fields: ["method"]`).
6. If a method was determined but isn't one of `GET`/`POST`/`PUT`/`PATCH`/`DELETE`
   → `UNSUPPORTED_HTTP_METHOD`.

`test_case.method` / `.endpoint` / `.path` / `.query` / `.request_body` /
`.auth_type` are **not** part of the documented Milestone 1 test case
schema - they are optional, forward-compatible fields this workflow reads
*if present*. Today's ingestion output never sets them, so in practice
every test case goes through the `steps`-parsing fallback. This gives a
future, richer test-script format (explicit Method/Endpoint/Body/Auth
columns) a path to override the parse without any change to this
workflow - see Future extension notes.

---

## Versioning

Same rules as `docs/contracts/planner-contract.md`:

- Bump `contract_version` when this contract's *shape* changes (new
  required field, renamed field, changed meaning) - not for new
  optional fields or new error codes.
- Bump `workflow_version` when `02-api-request-builder.json`'s internal
  logic changes in a way worth tracking, independent of whether the
  contract shape changed.
- This contract introduces the `workflow_version` / `contract_version`
  split described above. `planner-contract.md` currently only has
  `workflow_version` (no separate contract-shape version) - **recommended**
  for a future revision of that document to adopt the same split, not
  required by this task (Task 2/2.5 functionality is frozen unless a
  critical issue is found, and this is not one).

## Compatibility rules

- Consumers must branch on `item.status === 'ERROR'` before reading any
  other field - see `docs/contracts/error-payload.md`.
- Consumers must ignore unknown top-level fields rather than reject them.
- Embedding the full `test_case` object (beyond the task's suggested
  schema) is a deliberate addition: `request_id` alone isn't enough for a
  human debugging a failed request, or for the future Decision Agent,
  without the original description/expected_result/run_id. Since
  `planner-contract.md` already establishes "consumers ignore unknown
  fields," adding this field doesn't break anything that follows that
  rule.

## Future extension notes

- Adding a new authentication type means adding it to
  `SUPPORTED_AUTH_TYPES` in the `Build Authentication` node - not
  changing this contract's shape (`type` stays a string).
- Adding explicit Method/Endpoint/Body/Auth columns to a future,
  richer Excel template (or any new ingestion source) requires no change
  to `02-api-request-builder.json` at all - it already prefers explicit
  `test_case.method`/`.endpoint`/`.query`/`.request_body`/`.auth_type`
  over parsing `steps`, per "How method + endpoint are resolved" above.
- A future Repository/Database/UI agent (Milestone 2/3) does not consume
  this contract - it's specific to `agent: "api"` routes. Each agent type
  should get its own request/preparation contract when it's built, not be
  forced into this one's shape.
