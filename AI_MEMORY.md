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

## Task 4.0 (Decision Agent foundations) - things worth knowing

- ADR 005 replaced the documented `NOT_RUN` verdict state with
  `MANUAL_REVIEW` and dropped `next_action: "update_jira"` in favor of
  `flag_for_review` - `milestone-1.md` section 5 was amended to match.
  If anything still references `NOT_RUN`/`update_jira`, it's stale.
- `docs/architecture/decision-agent-design.md` is the full reasoning
  design (tier funnel, evidence rules, confidence calculation,
  hallucination guards, cost strategy). `docs/contracts/decision-contract.md`
  only specifies the shape that design produces - read both, the
  contract alone doesn't explain *why*.
- `docs/reviews/task-4.0-decision-agent-foundations-review.md` flagged
  four real gaps before implementation: the 0.7/0.8 confidence
  thresholds are uncalibrated placeholders; the evidence-grounding check
  has a concept but no algorithm; AI-service-failure handling was
  undesigned; the few-shot examples were untested against a real model.
  Task 4.1 resolved the AI-service-failure gap (see below); the other
  three are still open, deliberately out of scope for 4.1.

## Task 4.1 (Decision Orchestrator) - things worth knowing

- The workflow file is named `05-decision-orchestrator.json`, not
  `05-decision-agent.json` as earlier docs (`decision-contract.md`'s
  original Producer field, `workflow-standards.md`'s numbering table)
  had assumed before this task existed - both were updated to match.
  "Decision Agent" is still the correct conceptual role name used
  elsewhere in the docs; this file is that role's Task 4.1
  implementation, not a different concept. If a future doc still says
  `05-decision-agent.json`, it's stale.
- Resolved the AI-service-failure gap the Task 4.0 review flagged as
  undesigned: a failed AI call (network error, timeout, non-2xx from
  Anthropic) produces a single generic `AI_SERVICE_UNAVAILABLE` ERROR
  payload - deliberately not a classifier like 03's `codeFor()`, since
  anything more elaborate (retry, fallback, escalation) is AI failure
  recovery, out of scope for this task. This is a real design decision,
  not a placeholder - revisit only if a future task actually needs
  retry/escalation behavior.
- The confidence-threshold gate (PASS/FAIL below 0.7 confidence becomes
  MANUAL_REVIEW) is enforced in `Validate Decision Contract`, reading
  `decision-contract.md`'s own already-published Verdict States table -
  this is contract enforcement, not confidence recalibration. The
  model's reported confidence value is never adjusted, only which final
  `verdict.status` gets written out is gated by it. Don't confuse this
  with Task 4.4's evidence-based confidence *capping* (design doc
  section 3) - that adjusts the number itself and hasn't been built yet.
- The AI call uses Anthropic's Messages API directly via
  `n8n-nodes-base.httpRequest` (not a LangChain/AI-specific n8n node) -
  same reasoning as 03's HTTP Executor: a plain HTTP call to a
  well-documented, stable REST API is lower-risk than depending on an
  AI-node parameter schema that changes across n8n versions and
  couldn't be verified without a live instance anyway. `tool_choice`
  forces the model to call a `return_verdict` tool with a fixed JSON
  Schema - it cannot return free-form text, which is both the
  structured-output mechanism and a real (if partial) prompt-injection
  mitigation against a hostile response body in the evidence packet.
- The API key is supplied via an n8n Header Auth credential referenced
  by the `Claude` node (`credentials.httpHeaderAuth`), never via `$env`
  or embedded in the workflow JSON - see `n8n/credentials.example.json`.
  This deliberately avoids the exact anti-pattern the Task 3.2 review
  flagged (a real credential ending up in item data / execution logs).
- **The AI call itself was never exercised against the real Anthropic
  API** - no credential was available in this environment. Verified
  everything else (tier routing, evidence packet construction/exclusion
  rules, request building, response schema validation, the confidence
  gate, error handling) with a script harness that mocks the HTTP call's
  response shape - 50/50 checks passed at the time. Before trusting this
  in a real run: import into live n8n with a real credential and check
  at least one real Tier 2 call actually returns a `tool_use` block
  matching the assumed shape - that assumption is unverified.

## Task 4.2 (Decision Engine extraction) - things worth knowing

- The task's evidence example (`{ type: "status_code", expected: 200,
  actual: 200 }`) is an array of *objects*, but `decision-contract.md`
  (which this task explicitly must not modify) documents `evidence` as
  an array of *strings*. Resolved by keeping evidence as structured
  objects only *inside* the Decision Engine (Tier 0/Tier 1 build them),
  and rendering each to a descriptive string only in
  `Decision Engine - Finalize`, right before the public contract fields
  are written - the wire shape never changes, but the reusable
  component's internals genuinely are structured now. If a future task
  needs the Decision Contract's `evidence` field to actually carry
  objects, that's a real `contract_version` bump, not a quiet drift -
  don't let the renderer's presence become an excuse to skip that.
- Tier 0/Tier 1/the final-assembly node were renamed to
  `Decision Engine - Tier 0 (Transport)` / `Decision Engine - Tier 1
  (Exact Match)` / `Decision Engine - Finalize` and given a dedicated
  sticky note, but kept as an in-workflow node group rather than
  extracted to a separate sub-workflow file. Every workflow in this
  project so far "hands off" via a conceptual terminal NoOp, not a real
  n8n Execute Workflow call - introducing that untested mechanism here
  would have added risk beyond this task's scope. If a future task does
  extract this into a real sub-workflow, the group's minimal external
  coupling (everything it needs comes in via item fields the earlier
  nodes already set) should make that a low-effort lift.
- Reasoning/evidence-rendering wording changed slightly from Task 4.1
  (e.g. Tier 1's reasoning now reads "Expected HTTP 200 and received
  HTTP 200..." rather than "Expected status 200, received 200...") to
  track the task's own literal example more closely. This is a content
  change, not a shape change - `decision-contract.md` doesn't pin exact
  wording, only field types.

## Task 4.3 (AI Evaluation - Prompt Builder) - things worth knowing

- "Build AI Request" (Task 4.1) conflated two different concerns: the
  prompt content (system prompt text, user message from the evidence
  packet) and the Anthropic API-call structure (model, temperature,
  tool schema, tool_choice). Split into "Prompt Builder" (owns prompt
  content + evidence-allow-list re-verification) and "Build Claude API
  Request" (owns API-call structure only, consumes `item.__prompt`).
  Rationale: a future model swap (e.g. escalating to a stronger model
  per `decision-agent-design.md` section 8's cascade idea) should never
  risk touching prompt/evidence-filtering logic, and vice versa.
- "Prompt Builder" re-filters `__evidence_packet` down to the exact 7
  allow-listed keys even though "Build Evidence Packet" already
  constructs only those keys - genuine defense in depth, not redundant
  busywork. Verified with a test that deliberately leaks `request_id`/
  `jira_key` into the packet and confirms Prompt Builder still strips
  them before they'd reach the model.
- `__model_version` is set by "Build Claude API Request" (API-call
  concern); `__prompt_version` is set by "Prompt Builder" (prompt
  concern) and threaded through unchanged. Both still land in
  `decision_basis` at "Validate Decision Contract", which now reads
  `$('Build Claude API Request')` instead of the old `$('Build AI
  Request')` name - if a future search for "Build AI Request" turns up
  nothing, that's why.
- Same verification approach and same caveat as every prior task in this
  chain: script harness only (68/68 checks, up from 60), Claude call
  mocked - never run against a real Anthropic API or inside real n8n.
