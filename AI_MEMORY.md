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
