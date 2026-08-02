# AI Memory

Working notes for whichever AI assistant picks up this repo next. Not a
design doc - `docs/architecture/` and `docs/contracts/` are the source of
truth for how the system works. This file is for context that isn't
obvious from reading the code: what's been tried, what to watch out for,
where things stand.

## Read this first

Before touching a workflow: `docs/workflow-standards.md`, then the
specific contract(s) it produces/consumes in `docs/contracts/`, then the
workflow file itself. `PROJECT_STATUS.md` has the current per-task status.

## Environment notes

- No live n8n/Docker instance has been available while building through
  Task 3.2. Workflow JSON is hand-built to match the conventions in
  `01-ingestion.json` / `02-api-request-builder.json` and tested by
  extracting each Code node's `jsCode` and running it directly with a
  mocked n8n context (`$input`, `$env`, `$('NodeName')`) plus real network
  calls where relevant, rather than a from-scratch reimplementation of the
  logic. This caught two real bugs in Task 3.2 (see below) that a
  reimplementation would not have.
- Every workflow's node-level Code logic should be sanity-checked this way
  before considering a task done, until a real n8n instance is available
  to import and run workflows end-to-end.

## Task 3.2 (HTTP Executor) - things worth knowing

- The native HTTP Request node is configured with `neverError: true` so
  4xx/5xx responses come back as normal data (a `status_code` on the
  response contract), not thrown node errors. Only genuine execution
  failures (DNS, connection refused, timeout, malformed request) go
  through the node's error output.
- Error classification for that error output (`Build Network Error
  Payload`) has to look at more than one field - different HTTP clients
  put the real reason in different places (`err.code`, `err.message`,
  or nested under `err.cause`). An earlier version of this node only
  checked `error`/`message` and misclassified both a timeout (fetch's
  `AbortError: This operation was aborted` doesn't contain the word
  "timeout") and a connection-refused (Node's `fetch` wraps it as
  `fetch failed` with the real `ECONNREFUSED` nested in `err.cause.code`)
  as a generic `NETWORK_ERROR`. Fixed by folding `code`, `error`,
  `message`, `cause.code`, `cause.message`, and `name` into one string
  before pattern-matching. If a real n8n instance surfaces a differently-
  shaped error object, re-verify this node against it.
- Authentication credentials for the HTTP Executor are read from this
  workflow's own environment variables (`API_AUTH_BEARER_TOKEN`,
  `API_AUTH_API_KEY_HEADER`, `API_AUTH_API_KEY_VALUE`), not from the API
  Request Contract, which only ever carries a strategy marker (ADR 002).
  This is a placeholder for Milestone 1's single test target - a future
  milestone with multiple targets/credentials should move this to n8n's
  native credential store instead of plain env vars.
- A self-review of Task 3.2, written in the reviewer-not-implementer
  voice, lives at `docs/reviews/task-3.2-http-executor-review.md`. It's
  findings-only (no refactors applied) - biggest flagged risk is that
  nothing has run inside real n8n yet, so the native HTTP Request node's
  exact parameter names/shapes are unverified. Treat it as guidance, not
  a task list, per the instructions that introduced Task 3.3.

## Task 3.2 → 3.3: a critical defect found while building the consumer

While designing the Response Normalizer (Task 3.3), which is required to
preserve `test_case`/`expected` for *every* input including timeouts and
connection failures, it became clear `03-http-executor.json`'s error
payloads never carried either - only the success path
(`Build HTTP Response Contract`) did. Every error-producing node in 03
(`Validate API Request Contract`, `Validate URL And Method`, `Apply
Authentication`, `Build Network Error Payload`) was missing them.

Fixed by adding `test_case`/`expected` into the `details` object of every
error payload 03 produces - additive `details` content only, fully
sanctioned by `docs/contracts/error-payload.md`'s own rule that
workflow-specific context belongs in `details`, not a new top-level
field. `workflow_version` bumped `"1.0"` → `"1.1"` across all five Code
nodes in 03 for consistency (they'd drifted to have this literal
duplicated 5 times already - see the review doc's DRY finding #3; this
fix doesn't resolve that duplication, it just pays the tax of touching
all 5 copies once more). No shape change to the HTTP Response Contract's
success path or to the shared Error Payload itself.

This is the kind of gap that's invisible until you build the *consumer*
of a contract and try to actually satisfy its stated requirements -
worth remembering when building Task 4 (Decision Agent) against
`04-response-normalizer.json`'s output: check whether every field the
Decision Agent needs is actually present on every path (success,
transport failure, normalizer-level error), not just the happy path.

## Task 3.3 (Response Normalizer) - things worth knowing

- Unlike every earlier workflow, this one deliberately does **not**
  pass an upstream `status === 'ERROR'` item through unchanged. A
  transport failure from `03-http-executor` (timeout, connection
  refused, ...) already has `status: 'ERROR'`, and normalizing exactly
  that into a `transport.status` category is this workflow's whole job -
  passing it through untouched (the 01/02/03 convention for an error
  that isn't theirs to handle) would defeat the point. Every node uses
  `__kind` (`'error'` | `'response'`, set once by `Validate Contract`)
  to distinguish "still normalizing" from "this workflow already gave up
  and produced its own ERROR payload" (`!item.__kind`).
- `TRANSPORT_CODE_MAP` in `Normalize Transport` is a hand-kept allow-list
  from every `03-http-executor` error code to one of the seven transport
  categories. An HTTP Executor code with no entry produces
  `UNKNOWN_TRANSPORT_ERROR` rather than a silent guess - if a future
  change adds a new error code to 03, this map needs a matching entry or
  every instance of that new failure mode will surface as a normalizer
  error instead of a proper transport category.
- Verified the same way as Task 3.2: extracted the real `jsCode` from the
  committed workflow JSON and chained it exactly as n8n would connect the
  nodes, against synthetic inputs (not a from-scratch reimplementation).
  197/197 checks passed. Never run inside real n8n - same caveat as 3.2.
