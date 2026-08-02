# Decision Agent — Reasoning Engine Design

## Status
Draft — for discussion before Task 4 implementation begins. Not an ADR
yet. Nothing in this document is built. Two points explicitly need your
sign-off before implementation (see "Open decisions" immediately below)
because they diverge from what `docs/architecture/milestone-1.md` and
ADR 004 already specify.

---

## Open decisions (need sign-off before Task 4 starts)

**1. `MANUAL_REVIEW` vs. the documented `NOT_RUN`.**
`milestone-1.md` section 5 and ADR 004 specify `status` as one of
`PASS | FAIL | BLOCKED | NOT_RUN`. You asked for `PASS | FAIL | BLOCKED |
MANUAL_REVIEW`. These aren't the same state: `NOT_RUN` reads as "this
test never executed" (a strange thing for the Decision Agent to assert
*after* 03/04 already ran it), while `MANUAL_REVIEW` reads as "it ran, I
have a real response, but my confidence is too low to trust
autonomously" — a live low-confidence escape hatch, not a pre-execution
state. This document assumes `MANUAL_REVIEW` throughout because it's the
more useful state for the reasoning design below, but formalizing it
means writing a new ADR that supersedes/extends ADR 004 (per
`repository-design.md`'s "never edit old ones, add one that supersedes"
rule), not just quietly redefining the existing contract. **Recommend:**
write that ADR at the start of Task 4, before the workflow, so the
verdict contract is settled before the prompt is written against it.

**2. `next_action: "update_jira"` is unclear.** Milestone 1's Jira Agent
description says *it* checks for an existing open ticket and decides
comment-vs-create on its own — but `next_action`'s documented values
imply the *Decision Agent* is the one choosing `update_jira` vs.
`create_jira`. I don't have enough visibility into whether `test_case`
threading across repeat runs (via a persisted `jira_key`) is meant to
let the Decision Agent make that call, or whether `update_jira` is a
vestigial value from before the dedup logic moved into the Jira Agent.
**Recommend:** resolve this explicitly before Task 4 — possibly
`update_jira` never fires from the Decision Agent at all, and Jira Agent
downgrades every `create_jira` to a comment on its own when it finds a
duplicate. Not resolved in this document; flagged so it isn't silently
decided by accident during implementation.

Everything else below is a recommendation, not a decision — redirect any
of it.

---

## 1. How the AI should think

A real senior QA engineer doesn't re-derive every test from first
principles — they run a mental checklist, and only stop to actually
*think* when the checklist doesn't resolve it. The Decision Agent should
work the same way: **most of its "thinking" should never touch a model
at all.** This is also the single biggest lever for cost and
hallucination risk (sections 7-8), so it isn't just a reasoning-quality
choice, it's the load-bearing design decision this whole document hangs
off.

### The three-tier funnel

The tier boundary falls directly out of a field the pipeline already
computes: **`transport.status_code === null`** — normalized-response-contract.md
guarantees this is `null` if and only if no real HTTP response was ever
received (timeout, connection refused, DNS failure, or a pre-flight
validation reject in the HTTP Executor). No string-matching or category
enumeration needed to find the boundary; it's already a clean boolean.

**Tier 0 — Transport short-circuit (deterministic, no AI, always).**
```
if (transport.status_code === null) → status = BLOCKED
```
There is no real response to reason about, so there is nothing an LLM
can add — worse, asking a model to "explain" a connection refused
invites it to invent a plausible-sounding cause it has no actual
visibility into (a concrete hallucination risk, not a hypothetical one).
`reasoning` is templated directly from `transport.status` and the
underlying error, matching `milestone-1.md` section 8's own phrasing:
"reasoning = the error." This exactly matches the documented failure
handling table — it just makes explicit *why* it's correct to keep this
tier AI-free.

**Tier 1 — Exact-match fast path (deterministic, no AI).**
```
if (transport.status_code === expected.status) → status = PASS
```
Only fires when `expected.status` is a real parsed integer (from
`api-request-contract.md`'s best-effort parse of `expected_result`) and
it matches exactly. A senior engineer doesn't deliberate over "expected
422, got 422" — it's not a judgment call, it's arithmetic, and asking an
LLM to confirm arithmetic adds cost and a (small but nonzero) chance of
getting it wrong for zero benefit. `confidence = 1.0` always, since
there's no interpretive gap.

**Tier 2 — AI-assisted judgment.** Everything that reaches here has a
real response (`status_code` non-null) *and* isn't an unambiguous exact
match — either `expected.status` is null (only free-text
`expected_result`, nothing to arithmetically compare), the codes
mismatch, or the test's intent plausibly requires reading `response.body`
(the status code alone doesn't settle it). This is genuinely the only
tier where judgment is required, and it's the only tier that costs
anything.

### Why not just "always call AI, let the prompt handle simple cases"?

Because a model asked to confirm something already unambiguous adds
variance (temperature, phrasing sensitivity, rare miscalibration) to a
case that had zero variance before you asked it — you can only make an
arithmetic check *less* reliable by routing it through a language model,
never more. Reserve the model for the one thing it's actually needed
for: interpreting free text and body content against intent.

---

## 2. What evidence it should trust

The model should see **exactly** an evidence packet built for it — never
the raw Normalized Response Contract, never the full `test_case` object.
Two reasons: token cost, and contamination. `test_case` carries
traceability fields (`run_id`, `jira_key`, `agent_reasoning`,
`human_verdict`, `notes`, ...) that are either irrelevant to *this*
verdict or — worse — could be stale state from a *previous* run of the
same `test_id` if the object is ever threaded across repeat runs. A
model that can see last run's `agent_reasoning` might anchor on it
instead of judging the current evidence fresh.

**Evidence packet (everything the model is allowed to see):**
```json
{
  "description": "...",        // test_case.description
  "expected_result": "...",    // test_case.expected_result (free text)
  "expected_status": 422,      // expected.status, or null
  "actual_status": 200,        // transport.status_code
  "response_time_ms": 145,     // transport.response_time_ms
  "response_headers": {...},   // response.headers, filtered - see below
  "response_body": {...}       // response.body, possibly truncated - see section 8
}
```

**Explicitly excluded:** `request_id`, `response_id`, every traceability
field on `test_case`, the request that was sent (method/URL/auth) — none
of it is needed to judge the *response* against the *expectation*, and
including it only gives the model more surface area to reference
something irrelevant in its reasoning. `response_headers` should be
filtered to a small allow-list (`content-type`, maybe a rate-limit
header) rather than dumped whole — most response headers are noise for
this judgment and some (any tracing/session headers) shouldn't be
casually forwarded into a Jira ticket description later.

**Trust hierarchy, most authoritative first:**
1. `actual_status` — already normalized fact, never re-derived, never
   questioned by the model.
2. `expected_status` / `expected_result` — the test author's stated
   intent, treated as ground truth for *what should happen*, not
   re-interpreted.
3. `response_body` — supporting evidence for *why*, used to explain a
   mismatch or confirm a body-content expectation; never used to
   override a clean status-code determination in the opposite direction.
4. Nothing else. No prior-turn memory, no other test case's outcome, no
   inference not traceable to 1-3.

---

## 3. How confidence is calculated

Self-reported LLM confidence is well-documented as poorly calibrated —
models cluster near 0.9+ regardless of actual certainty. Treat the
model's self-reported number as **one input to a rules-anchored score**,
never the score itself.

- **Tier 0 / Tier 1 (deterministic):** `confidence = 1.0`, always. No
  model was involved; there's no uncertainty to report.
- **Tier 2 (AI-assisted):** `confidence = min(model_reported, evidence_cap)`
  where `evidence_cap` comes from a fixed rule table, not the model:

| Situation | Cap |
|---|---|
| `expected_status` present, clear numeric mismatch (e.g. expected 422, got 200) | 0.95 — unambiguous, the model mainly needs to write the explanation |
| `expected_status` is `null`, only free-text `expected_result` | 0.75 — real interpretive judgment involved |
| `expected_result` implies body-content verification but `response_body` is empty/null | 0.4, and **forced to `MANUAL_REVIEW`** regardless of what the model concluded — see hallucination guard below |
| Model's `evidence` array references something not traceable to the evidence packet (grounding check fails) | forced to `MANUAL_REVIEW`, confidence irrelevant |

- **Routing threshold:** `create_jira` only fires at `confidence >= 0.8`
  on a `FAIL`. A low-confidence FAIL routes to `flag_for_review` instead
  — filing a ticket is a real-world action with a cost (someone's time),
  so it should demand a higher bar than just writing a report row.

---

## 4. When it returns PASS / FAIL / BLOCKED / MANUAL_REVIEW

Each state gets one unambiguous, non-overlapping trigger — no case
should be reachable by two different paths:

| Status | Trigger | Tier |
|---|---|---|
| `BLOCKED` | `transport.status_code === null` (no real response was ever obtained — a *system* failure, never a statement about the API under test) | 0 |
| `PASS` | Real response received, and it satisfies `expected` (exact match, or AI-confirmed semantic match) at `confidence >= 0.7` | 1 or 2 |
| `FAIL` | Real response received, and it contradicts `expected`, at `confidence >= 0.7` | 2 (mismatches never reach Tier 1) |
| `MANUAL_REVIEW` | Real response received, AI attempted judgment, but confidence fell below 0.7, evidence was insufficient, or a hallucination guard (section 7) rejected the model's output | 2 |

`next_action` stays the single field downstream agents branch on
(consistent with `milestone-1.md` section 5's "never re-derive a verdict
from prose" rule): `write_report` (PASS, always reported, no ticket),
`create_jira` (FAIL at sufficient confidence), `flag_for_review` (new
value, proposed — `MANUAL_REVIEW`, or a low-confidence FAIL), `none`
(BLOCKED — no ticket, per `milestone-1.md` section 8; still likely
`write_report`'d by Documentation Agent for the record, which is a
Documentation Agent scope question, not this workflow's).

---

## 5. The exact JSON verdict contract

Proposed shape — a deliberate evolution of `milestone-1.md` section 5's
flatter sketch, grouping "judgment" fields separately from "provenance"
fields that are only ever carried forward, never computed by this
workflow:

```json
{
  "workflow_version": "1.0",
  "contract_version": "1.0",
  "request_id": "f7edb8a1-32a7-4df9-a3ff-bb49bbeada8e",
  "response_id": "a2c9e410-9e3b-4f1a-8b2d-3e6f1a7c9d0b",
  "test_case": { "...": "carried forward unchanged, per every prior contract's convention" },
  "verdict": {
    "status": "FAIL",
    "confidence": 0.95,
    "reasoning": "Expected 422 Unprocessable Entity for a 5-character password; API returned 200 OK and created the account.",
    "evidence": [
      "expected_status: 422",
      "actual_status: 200",
      "response_body.created: true"
    ],
    "next_action": "create_jira"
  },
  "decision_basis": {
    "tier": "ai_assisted",
    "model_version": "claude-haiku-4-5-20251001",
    "prompt_version": "v1"
  },
  "metadata": {
    "decided_at": "2026-08-02T10:00:00.000Z",
    "source_workflow": "04-response-normalizer",
    "next_workflow": "06-documentation-agent"
  }
}
```

`decision_basis` is the deliberate addition beyond the original sketch:
it makes "was this a $0 deterministic rule or a paid model call"
trivially auditable per verdict — essential for both the cost tracking
in section 8 and for any later hallucination post-mortem ("show me every
verdict tier 2 produced last week"). `tier` is one of
`deterministic_transport` (Tier 0) / `deterministic_exact_match` (Tier
1) / `ai_assisted` (Tier 2); `model_version`/`prompt_version` are `null`
for Tiers 0-1, populated only for Tier 2 — reusing the fields
`milestone-1.md` section 7 already reserved on `test_case` for exactly
this purpose.

---

## 6. Prompt engineering strategy

- **Schema-enforced output, not requested output.** Use forced tool-use
  / structured output (a strict JSON schema the API enforces), not "please
  respond in JSON" prose instructions hoping for compliance. The verdict
  shape is load-bearing for the entire rest of the pipeline (ADR 004) —
  it should be enforced at the API boundary, not just requested.
- **Versioned prompt file**, per `repository-design.md`'s existing
  convention: `prompts/decision-agent/v1.md`, never overwritten — new
  versions get new files so `prompt_version` in the contract means
  something months later.
- **Few-shot anchoring.** 2-3 worked examples in the system prompt: one
  clean status-code FAIL with body confirmation, one case that should
  resolve to `PASS` despite a *semantically* equivalent but *numerically*
  different status (e.g. 201 vs. a loosely-worded "should succeed"
  expectation) to calibrate that exact-match isn't the only path to
  PASS, and one genuinely ambiguous case that should resolve to
  `MANUAL_REVIEW` — explicitly showing the model that admitting
  uncertainty is a valid, expected output, not a failure to produce an
  answer.
- **Explicit instruction to refuse to guess:** "You may only cite facts
  present in the evidence block below. If the evidence needed to judge
  isn't present, return `MANUAL_REVIEW` and say what's missing." This is
  simultaneously a prompt-engineering technique and a hallucination
  guard (section 7) — the two aren't separable here.
- **Temperature 0** (or as close as the model allows). This is a
  judgment task requiring repeatability, not creative generation — the
  same evidence run twice should produce the same verdict, which matters
  for both auditability and for anyone ever debugging "why did this test
  flip."
- **Single-turn, stateless.** No conversation history across test cases
  in a batch — prevents one test's evidence from leaking into another's
  reasoning, and keeps per-call cost flat regardless of batch size.

---

## 7. Hallucination guards

Layered, not single-point — treat AI output with the same "never trust,
always validate" discipline this project already applies to Excel rows
and HTTP responses (`docs/workflow-standards.md`'s validation rules
apply here too, the input is just a model response instead of a file).

1. **Evidence allow-list (section 2).** If it was never in the packet,
   it cannot be a truthful basis for a claim — the hardest and cheapest
   guard, enforced before the call is even made.
2. **Schema validation on the way out.** A deterministic Code node
   re-validates the model's structured response against the exact shape
   in section 5, same as every other contract in this repo — reject and
   retry once on a malformed response, then `MANUAL_REVIEW` on a second
   failure rather than looping indefinitely.
3. **Grounding check on `evidence[]`.** Each entry should be
   mechanically checkable against the evidence packet (does the quoted
   status code, field name, or value actually appear in what was given
   to the model?). An entry that doesn't ground is a concrete
   hallucination signal — downgrade to `MANUAL_REVIEW`, don't silently
   keep the verdict.
4. **Deterministic veto on empty-body claims.** If `expected_result`'s
   language implies content verification but `response_body` is
   null/empty, force `MANUAL_REVIEW` regardless of the model's
   conclusion — an empty body cannot ground any specific-content claim,
   full stop, so any verdict resting on one is definitionally
   ungrounded.
5. **Cross-check against the Tier-1 signal, even inside Tier 2.** The
   naive `actual_status === expected_status` boolean is cheap to compute
   alongside every Tier 2 call. If it's `true` (a clean match) but the
   model says `FAIL`, that's a disagreement between a known-reliable
   deterministic signal and the model — treat as a suspected
   hallucination and route to `MANUAL_REVIEW` rather than trusting the
   model over arithmetic.
6. **No tool access beyond returning the verdict.** The model cannot
   re-call the API, browse, or fetch anything else — its entire
   knowable world is the evidence packet, which caps the hallucination
   surface to "misreading given text," never "inventing an external
   fact."
7. **No echoing secrets/PII into `reasoning`/`evidence` uncritically** —
   low priority against Milestone 1's fake test target, but worth naming
   since `response_body` flows fairly directly toward a Jira ticket
   description later (Jira Agent, Task 4+), and that's a real-world
   consequence of what this workflow decides to quote.

---

## 8. Cost optimization

- **The tier funnel (section 1) is the primary lever**, not model
  choice. Most real-world API test suites are majority simple
  status-code checks — Tiers 0-1 likely resolve a large fraction of
  cases for $0 and zero latency, before any model-selection question
  even matters.
- **Cascade, don't default to the biggest model.** Tier 2's task (single
  turn, tight evidence packet, structured output) doesn't need a
  frontier reasoning model - a fast/cheap model is very likely
  sufficient as the first pass. Escalate to a stronger model only when
  the cheap model itself returns `MANUAL_REVIEW` or a confidence near
  the threshold - most Tier 2 calls should never need the escalation.
- **Prompt caching.** The system prompt (role instructions + few-shot
  examples + schema) is static across every test case in a run - cache
  it so only the small per-test evidence packet is billed at full price
  each call.
- **Truncate oversized response bodies** before they enter the prompt,
  with an explicit marker that truncation happened and an instruction
  that the model should return `MANUAL_REVIEW` rather than guess if the
  evidence it needs might be in the truncated portion - paying to
  include a multi-hundred-KB body in full is rarely buying better
  judgment.
- **Stateless per-call (deliberate tradeoff, not free).** Keeping calls
  isolated (section 6) forgoes any batching discount in exchange for
  reliability/isolation - naming this explicitly rather than treating it
  as costless, since it is a real tradeoff.
- **Measure the split, don't assume it.** `decision_basis.tier` on every
  verdict (section 5) makes it possible to later ask "what fraction of
  real runs actually needed Tier 2?" and validate the funnel is doing
  what it's designed to do, rather than taking the cost story on faith.

---

## Summary table

| Question | Answer |
|---|---|
| How does it think? | A 3-tier funnel anchored on `transport.status_code === null` and exact-match arithmetic; AI only for genuine interpretation |
| What evidence does it trust? | A deliberately minimal, allow-listed packet - never the raw contract or full `test_case` |
| How is confidence calculated? | Rules-anchored caps on top of (never a straight pass-through of) the model's self-report |
| When PASS/FAIL/BLOCKED/MANUAL_REVIEW? | One unambiguous trigger each, keyed off `status_code` nullness and confidence threshold |
| Verdict contract? | `verdict` grouped separately from carried-forward provenance, plus a new `decision_basis` block for auditability |
| Prompt strategy? | Schema-enforced output, versioned prompt file, few-shot anchoring, temp 0, stateless |
| Hallucination guards? | Allow-listed evidence, schema validation, grounding checks, deterministic vetoes, cross-check against Tier 1, no tool access |
| Cost optimization? | The tier funnel first; cheap-model-first cascade; prompt caching; body truncation |

Nothing here is implemented. Next step, if this direction looks right,
is resolving the two open decisions above and writing the superseding
ADR before touching `n8n/workflows/05-decision-agent.json`.
