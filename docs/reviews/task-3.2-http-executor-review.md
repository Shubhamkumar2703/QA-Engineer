# Self-Review: Task 3.2 — HTTP Executor

Reviewer: implementer, in senior-engineer-reviewing-a-PR mode.
Scope: `n8n/workflows/03-http-executor.json` and
`docs/contracts/http-response-contract.md`, in the context of the two
workflows it sits between (`02-api-request-builder.json`,
`04-response-normalizer.json` — not yet built).

This is a findings document only. Nothing here is implemented. Items are
ordered roughly by severity within each section. Nothing recommended
requires expanding Milestone 1 scope — these are all quality/robustness
improvements to what Task 3.2 already claims to do.

---

## 1. Biggest risk: none of this has run inside real n8n

Every check in the completion report exercised the Code nodes' `jsCode`
directly (extracted from the committed JSON, run under Node with a
hand-mocked `$input`/`$env`/`$()`), plus real HTTP calls via Node's
`fetch`. That's a legitimate way to validate business logic without a
running instance, but it does **not** validate:

- Whether `n8n-nodes-base.httpRequest` typeVersion `4.2` actually accepts
  the parameter names used (`specifyQuery`, `jsonQuery`, `specifyHeaders`,
  `jsonHeaders`, `sendBody`, `specifyBody`, `jsonBody`,
  `options.response.response.fullResponse`,
  `options.response.response.neverError`). These were written from
  memory of the node's shape, not copied from a live export.
- Whether a **boolean-typed parameter** (`sendBody`) can legally hold a
  full expression string (`"={{ $json.__body !== null }}"`) in exported
  JSON, or whether n8n expects a literal `true`/`false` with the
  conditional logic expressed differently (e.g. via `disableBodyForGet`
  style flags or a fixed `true` plus letting `jsonBody` be `"null"`).
- Whether `"onError": "continueErrorOutput"` at the node's top level is
  the correct key/value for the pinned n8n version, and whether the
  error-output item shape actually looks like `{ error, message }`/`{
  code, cause }` the way `Build Network Error Payload` assumes — this was
  inferred from Node's own `fetch`/`undici` error shapes, not from n8n's
  actual HTTP client (which may be axios-based depending on version).
- Whether `$('Apply Authentication').item.json` resolves correctly when
  n8n is processing multiple items in one execution (paired-item
  resolution across a linear chain is normally safe, but it was never
  exercised with more than one item in flight at once).

**Recommendation:** before this workflow is trusted, import it into a
real n8n instance, run one item through end-to-end, and diff the actual
exported JSON n8n produces for the HTTP Request node against what's
committed. Treat everything above as unverified until then. This is
already noted as a recommendation in the completion report, but it
belongs here too as a design risk, not just a follow-up task.

---

## 2. Security: the credential-avoidance design is undone at execution time

`docs/contracts/api-request-contract.md` is explicit that a real
credential must never appear in workflow item data, because n8n
execution data is visible in the UI and potentially persisted/logged —
that's the entire reason `authentication.credentials` is a marker, not a
secret.

`Apply Authentication` in this workflow then does exactly the thing that
was being avoided: it reads the real token from `$env` and writes it
directly into `item.json.__headers.Authorization`, which becomes part of
every downstream item's data — including whatever n8n persists for that
execution (subject to n8n's "save execution progress" setting, which
defaults to saving). The bearer token or API key value will be visible in
plaintext in the n8n execution log for every run that uses non-`none`
auth.

This isn't a bug relative to what Task 3.2 was asked to do (something has
to attach the real credential somewhere, and the task explicitly assigns
that job to this workflow), but it's a real regression against the
principle the earlier contract went out of its way to establish, and it
should be a known, named risk rather than an implicit side effect.

**Recommendation (not for this task):** n8n's native HTTP Request node
supports referencing a stored **credential** (its own encrypted store)
instead of a header built from `$env` in a Code node — the token would
never appear in item JSON or execution data at all. `authentication.type`
could map to a credential *name* to look up rather than an env var to
read. This is a bigger change (n8n credentials aren't provisionable via
JSON export the way workflows are) so it's appropriately out of scope for
Task 3.2, but it should be flagged before this goes anywhere near a real
API key.

---

## 3. Duplicated logic across workflows (confirmed by inspection, not guesswork)

Checked directly against the committed JSON:

| Thing duplicated | Where |
|---|---|
| `function errorPayload(code, message, details) {...}` | 3 separate nodes in `03-http-executor.json` alone (`Validate API Request Contract`, `Validate URL And Method`, `Apply Authentication`) — and the same helper is independently re-typed in every node of `01-ingestion.json` and `02-api-request-builder.json` too |
| `const WORKFLOW_VERSION = '1.0'` literal | 5 separate nodes in `03-http-executor.json` |
| `function uuidv4() {...}` | Once in `02-api-request-builder.json`, once again (byte-for-byte identical) in `03-http-executor.json` |
| `SUPPORTED_METHODS` allow-list | `02-api-request-builder.json` (`Validate Test Case`) and `03-http-executor.json` (`Validate URL And Method`) — two independently-maintained copies of the same 5-element array |
| `SUPPORTED_AUTH_TYPES` allow-list | Same pattern, `Build Authentication` (02) vs `Apply Authentication` (03) |

None of this is a bug today — every copy is currently identical — but
it's the textbook setup for drift: add a 6th HTTP method or a new auth
type in one workflow's array and forget the other, and the mismatch
won't surface as an error, it'll surface as an inconsistency where 02
happily builds a request that 03 then rejects (or vice versa) for a
method/auth type that's "supported" in one place and not the other.

This is a known constraint of n8n's Code node model (no shared
module imports across nodes without a custom node), so it's not a
Task-3.2-specific mistake — `docs/workflow-standards.md` already
acknowledges the same problem for `SUPPORTED_VERIFICATION_TYPES` /
`AGENT_ROUTES` ("kept in sync by hand ... not enforced") — but Task 3.2
adds two more instances of the same pattern and the standards doc doesn't
yet list them.

**Recommendation:** add `SUPPORTED_METHODS` and `SUPPORTED_AUTH_TYPES` to
the "kept in sync by hand" note in `docs/workflow-standards.md` next to
the existing `SUPPORTED_VERIFICATION_TYPES` callout, so the coupling is
at least documented in the one place someone would look. If a 4th or 5th
workflow ever needs the same allow-lists (Response Normalizer plausibly
will, to know what it's normalizing), that's the point where a shared
approach (e.g. a small `n8n-nodes-base.set`-populated "constants" item
merged into every execution, or committing to duplicate-with-comments as
a deliberate convention) needs an actual decision, not another silent
copy.

---

## 4. Coupling between workflows

- **String-keyed node references.** `Build HTTP Response Contract` and
  `Build Network Error Payload` both call
  `$('Apply Authentication').item.json`. Renaming that node breaks both
  downstream nodes, silently, with no error until the workflow actually
  executes (n8n doesn't validate cross-node expression references at
  save time in a way that would catch a typo here). This is inherent to
  how n8n Code nodes reference siblings, but it means `Apply
  Authentication` is now a de facto public interface — its name is load-
  bearing for two other nodes — worth a comment at the node itself, not
  just implied by convention.
- **Magic string `next_workflow: '04-response-normalizer'`** is
  hand-typed in `Build HTTP Response Contract`'s output and nowhere
  derived from a shared source of truth. `docs/workflow-standards.md`'s
  numbering table is the actual source of truth, but nothing ties the
  literal string in the Code node back to that table — if a workflow
  ever gets renumbered, this is a silent-drift risk identical in shape to
  the `SUPPORTED_METHODS` issue above, just for metadata instead of
  validation logic.
- **Implicit body-shape contract between 02 and 03.** `Build Request` in
  02 always sets `Content-Type: application/json` and 03's HTTP Request
  node always JSON-stringifies `__body`. This is a reasonable assumption
  for Milestone 1 (there's no other content type in play), but it's an
  invariant that exists only by convention between two files — nothing
  documents "the executor assumes every body is JSON" as an explicit
  contract clause the way, say, the auth strategy is documented. If a
  future test case needs a form-encoded or multipart body, both
  workflows need coordinated changes and there's currently nothing
  pointing a future implementer at that coupling.

**Recommendation:** no code change needed now, but
`docs/contracts/api-request-contract.md` (or the response contract) could
gain one sentence stating the JSON-body assumption explicitly, the same
way the authentication section explicitly states its own assumptions.

---

## 5. Design weaknesses inside this workflow specifically

- **`latency_ms` measures more than network time.** `__start_ms` is
  stamped in `Apply Authentication`, not immediately before the HTTP
  Request node fires. Everything between those two points — the `Route
  Validation Errors` IF node's evaluation, n8n's own inter-node
  handoff/serialization — gets counted as request latency even though
  none of it is the actual HTTP round trip. For a single-request-at-a-
  time Milestone-1 run this is probably negligible, but the contract doc
  currently describes `latency_ms` as "wall-clock milliseconds between
  sending the request and receiving the response," which overstates the
  precision of what's actually measured. Either the doc's wording should
  be softened ("...between the executor beginning to process the request
  and receiving the response") or the start-time stamp should move to
  immediately before the HTTP node — the latter isn't cleanly possible
  today because Code nodes and the HTTP node are separate steps with no
  hook in between.
- **Error-code classification is a string-matching heuristic, not a
  contract.** `codeFor()` in `Build Network Error Payload` pattern-
  matches lowercase substrings (`'econnrefused'`, `'timeout'`, `'abort'`,
  ...) across whatever fields happen to be present on the thrown error.
  This already needed one real fix during testing (see `AI_MEMORY.md`)
  precisely because different HTTP clients shape errors differently, and
  it was only tested against Node's own `fetch`, never against n8n's
  actual HTTP client. Any error shape not anticipated here silently falls
  through to `NETWORK_ERROR` — not wrong per the contract (`NETWORK_ERROR`
  is an explicit catch-all), but it means `TIMEOUT_ERROR` and
  `CONNECTION_REFUSED` are best-effort classifications, not guarantees,
  and that's not visible anywhere except this review and the error
  payload doc's error-code table.
- **Two different mechanisms express the same "is this an error" check.**
  Every Code node in the chain does `if (item.status === 'ERROR') return
  { json: item }`. Additionally, `Route Validation Errors` is a whole
  separate IF node re-doing the identical check, needed only because the
  native HTTP Request node has no way to early-return on its own. That's
  functionally necessary (can't put a `status==='ERROR'` guard inside a
  built-in node), but it means a reader has to know two different idioms
  represent one concept, which is exactly the kind of inconsistency
  `docs/workflow-standards.md`'s "one job per node" rule is meant to
  guard against at a finer grain. Worth a one-line comment on `Route
  Validation Errors` explaining *why* it exists (duplicating, not
  replacing, the Code nodes' own checks) so a future reader doesn't
  "simplify" it away as redundant.

---

## 6. Scalability concerns (Milestone 2+, not blocking now)

- **Single global credential set.** `API_AUTH_BEARER_TOKEN` /
  `API_AUTH_API_KEY_VALUE` are process-wide env vars — every request in
  every execution uses the same credential regardless of test case or
  target API. Fine when Milestone 1 has exactly one `SWAGGER_BASE_URL`;
  breaks the moment a second target API with different auth shows up
  (Milestone 2's Repository/Database agents plausibly hit different
  systems). There's no per-test-case or per-target credential selection
  mechanism today.
- **No retry / backoff.** A single flaky 503 becomes a permanent data
  point with no re-attempt. Not required for Milestone 1 (the Decision
  Agent can presumably just call it a FAIL), but worth naming now since
  adding retries later means deciding where retry state lives (this
  workflow? a wrapper around it?) and that's easier to plan for than to
  retrofit.
- **No persistence of what happened.** ADR 003 commits to Postgres for
  logging (`runs`/`decisions` tables), but nothing in this workflow
  writes `status_code`/`latency_ms`/`response_id` anywhere durable — the
  HTTP Response Contract only flows to the next in-memory node. If a run
  crashes between here and the Decision Agent, the fact that this request
  executed (and what it returned) is gone. Likely intentional deferral
  (Documentation Agent's job, or a later logging task), but it's not
  written down anywhere that this is deferred vs. forgotten.
- **No idempotency guard.** If n8n's own retry-a-failed-execution feature
  is ever used on this workflow, the same `request_id` would produce a
  second `response_id` from a second real HTTP call — fine for a GET,
  potentially not fine for a POST that creates a resource. Not a
  Milestone-1 concern (no auto-retry is configured), but worth a note for
  whoever eventually turns on n8n's retry settings.

---

## 7. Testing gaps (relative to what was actually verified)

The 89 checks in the completion report are real and did catch a real
bug, but they have blind spots worth naming plainly rather than letting
the "89/89 passed" framing overstate confidence:

- Never ran against the actual `n8n-nodes-base.httpRequest` node — only
  against Node's `fetch`, as covered in section 1.
- Never tested `UNSUPPORTED_AUTHENTICATION` in `Apply Authentication`
  (only `MISSING_CREDENTIALS` was exercised for the auth-error path).
- Never tested malformed `headers`/`query` shapes in `Validate API
  Request Contract` (e.g. `headers` as an array, `query` as a string) —
  the code path exists but has no corresponding check in the harness.
- Never tested more than one item per execution — every check ran a
  single item through the chain, so paired-item resolution
  (`$('Apply Authentication').item.json` picking the *matching* item, not
  just *an* item) was never actually exercised under concurrency.
- Never tested a response body that isn't JSON (the harness always hits
  JSON-returning httpbin endpoints) — `Build HTTP Response Contract`'s
  `httpResult.body` handling for a plain-text or binary response is
  unverified.

None of these need to block anything — they're gaps to close once a real
n8n instance is available, and several of them (multi-item, non-JSON
body) are exactly the kind of thing that's cheap to add to the existing
harness once the higher-priority "does this even work in real n8n"
question (section 1) is answered.

---

## 8. What's holding up well

For balance, since a review that's all findings reads as harsher than
intended:

- The ERROR-payload-everywhere convention is followed consistently and
  correctly — every failure mode in this workflow, including ones this
  task added (`INVALID_URL`, `TIMEOUT_ERROR`, `CONNECTION_REFUSED`, etc.),
  produces the shared shape with `request_id` preserved in `details`,
  matching `docs/workflow-standards.md`'s "fail loudly, never silently"
  rule.
- `expected` and `test_case` being carried forward unchanged (never read,
  never compared) is the correct way to keep this workflow honestly
  scoped to execution-only, while still leaving the Decision Agent
  everything it needs without a second lookup.
- The `neverError` + separate error-output-branch split cleanly
  separates "the target answered, just not with 2xx" from "the target
  never actually answered" — which is the right seam for this workflow's
  stated non-goal of not judging PASS/FAIL.

---

## Summary of recommendations (no scope expansion)

1. **Before trusting this in a real run:** import into live n8n, run one
   item end-to-end, and diff the HTTP Request node's actual parameter
   shape against what's committed (section 1).
2. **Name the credential-exposure tradeoff** explicitly in
   `docs/contracts/http-response-contract.md` or a short ADR, even if the
   fix (native n8n credentials instead of env-var headers) is deferred
   (section 2).
3. **Add `SUPPORTED_METHODS` / `SUPPORTED_AUTH_TYPES`** to
   `docs/workflow-standards.md`'s existing "kept in sync by hand" note
   (section 3) — a documentation-only change, no code.
4. **Add one sentence to a contract doc** stating the JSON-only body
   assumption shared between 02 and 03 (section 4).
5. **Soften or correct the `latency_ms` wording** in
   `docs/contracts/http-response-contract.md` to reflect what's actually
   measured (section 5).
6. **Add a one-line comment on `Route Validation Errors`** explaining why
   it duplicates the Code nodes' own `status === 'ERROR'` checks, so it
   doesn't read as redundant to a future maintainer (section 5).
7. **Extend the test harness** (not the workflow) to cover
   `UNSUPPORTED_AUTHENTICATION`, malformed headers/query shapes,
   multi-item executions, and non-JSON response bodies once a real n8n
   instance makes the section-1 verification possible (section 7).

None of the above changes the HTTP Executor's responsibilities, and none
of them pull in Response Normalizer, Decision Agent, or credential-store
work — they're all tightening what Task 3.2 already built.
