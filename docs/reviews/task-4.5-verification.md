# Task 4.5 — Decision Engine Verification, Benchmark & Calibration Report

## Status
Complete. Verification and benchmarking sprint - no new business features,
no architecture changes. See "Verification updates" below for the one
(zero-diff) check on whether `05-decision-orchestrator.json` needed
changes.

## Scope and method

Every finding in this report comes from one of two sources, both run
against the actual, committed `n8n/workflows/05-decision-orchestrator.json`
- never a reimplementation:

1. **The existing script harness** (`test-decision-orchestrator.cjs`,
   built across Tasks 4.1-4.4) - extracts every node's real `jsCode` and
   chains it exactly as n8n would connect the nodes. Re-run for this
   task: **82/82 passing, zero regressions.**
2. **A new benchmark harness** (this task), which does the same
   extraction, but for the AI step calls a **real, locally-running Ollama
   server** (`http://localhost:11434`, model `llama3:latest`) instead of
   a scripted response. This is genuine, not simulated: every timing,
   token count, and model output in this report came from an actual
   inference call made during this session.

**What could not be tested:** a real Anthropic API call. No Anthropic
credential is available in this environment (same limitation noted in
every prior task's report). All Claude-path verification in this report
is against mocked responses, same as Tasks 4.1-4.4 - it re-confirms
logic correctness, not real Claude behavior or latency.

---

## 1. End-to-end verification

Every stage in the requested flow was exercised with real, extracted
node code:

```
Normalized Response → Validate Contract → Tier Engine → Prompt Builder → LLM → Trust Layer → Decision Contract
```

| Stage | Verified how | Result |
|---|---|---|
| `Validate Contract` | Malformed/missing-field inputs, well-formed inputs, upstream ERROR passthrough | Correct on all paths (existing 82-check suite) |
| Tier Engine (`Decision Engine - Tier 0/1/Finalize`) | Transport failure → `BLOCKED`; exact status match → `PASS`; everything else → routes to AI | Correct; zero AI calls on Tier 0/1 (confirmed via call-counter in the harness) |
| `Build Evidence Packet` → `Prompt Builder` | Allow-list construction, defense-in-depth re-filtering, system prompt assembly | Correct; confirmed the *exact* embedded system prompt (not a paraphrase) was sent to a real model in this task's benchmark |
| LLM (Claude, mocked / Ollama, real) | Forced tool-call (Claude) vs. prompt-instructed JSON (Ollama - see section 2) | Both paths produce a response `Validate AI Response Shape` can consume, once normalized - see section 2 for what "once normalized" required |
| Trust Layer (`Validate AI Response Shape` → `Ground Evidence` → `Apply Trust Rules`) | Structural rejection, grounding computation, confidence capping, hallucination/decisive-confidence handling | Correct on all 5 real Ollama responses and all mocked Claude responses - see sections 3-5 for what this actually caught |
| Decision Contract output | Field-by-field shape check against `docs/contracts/decision-contract.md` | Unchanged, confirmed identical shape across deterministic and AI-assisted paths |

**Verification updates to `05-decision-orchestrator.json`: none required.**
Every stage behaved exactly as designed in Tasks 4.1-4.4, including on
inputs the workflow had never actually seen before (real model text,
including one malformed response - see section 5). No bug was found;
nothing was changed.

---

## 2. LLM Adapter Validation / model portability

### What's actually model-agnostic already

`Ground Evidence` and `Apply Trust Rules` operate **only** on the
normalized `__raw_verdict = {status, confidence, reasoning, evidence}`
shape that `Validate AI Response Shape` produces. Nothing below that
point references Anthropic, Claude, or any provider-specific structure.
This was already true by construction from Task 4.4's design; this task
is what actually proves it: **the same `Ground Evidence`/`Apply Trust
Rules` code, unmodified, processed real Ollama output and produced
correctly capped, correctly graded verdicts** (section 4) identical in
shape and behavior to what it does with mocked Claude output.

### The precise coupling seam (documented, not fixed)

Two nodes assume Anthropic's Messages API shape specifically, and would
need a provider branch (or a second adapter node pair) to genuinely
support a second provider in the live workflow:

- **`Build Claude API Request`** builds Anthropic's specific request
  body: `tools[].input_schema` + `tool_choice: {type:"tool", name:...}`.
  This is Anthropic's own tool-calling shape - OpenAI-compatible APIs
  (which Ollama partially supports for *some* models) use a different
  shape (`tools[].function.parameters` + `tool_choice:
  {type:"function", function:{name:...}}`).
- **`Validate AI Response Shape`** looks for
  `aiResponse.content[].type === 'tool_use'` - Anthropic's specific
  response location and encoding (the tool input arrives as an
  already-parsed object). An OpenAI-compatible response would put it at
  `choices[0].message.tool_calls[0].function.arguments` - and critically,
  as a **JSON string**, not a parsed object.

To genuinely add Ollama (or any second provider) as a live option in
this workflow, the additive, non-redesigning change would be: a second
`Build <Provider> API Request` node, a second HTTP node pointed at that
provider, and a second `Validate <Provider> AI Response Shape` node that
normalizes into the same `__raw_verdict` shape - then everything
downstream (Ground Evidence, Apply Trust Rules, Decision Contract
assembly) needs zero changes. This is a real, scoped, additive
recommendation for a future task, not something this task builds.

### A model-portability assumption this task discovered

**The locally available model does not support native tool-calling.**
Confirmed by a live probe:

```
$ curl http://localhost:11434/api/chat -d '{"model":"llama3:latest","tools":[...]}'
{"error":"registry.ollama.ai/library/llama3:latest does not support tools"}
```

This benchmark's Ollama adapter therefore uses **prompt-instructed JSON**
(ask the model to emit raw JSON matching the schema, then parse the
text) instead of Claude's forced `tool_choice`. This is not a defect in
the Decision Engine - it's a real capability difference between
providers/models worth naming explicitly: **Claude's structured output
is enforced by the API; a non-tool-calling local model's JSON
conformance is requested, not guaranteed.** Section 5 quantifies how
often that requested-not-guaranteed conformance actually failed in this
benchmark (1 malformed response out of 5 real calls).

**Documented assumption for `prompts/decision-agent/v1.md` reuse across
providers:** the prompt's Rule 6 ("Return your verdict using the
`return_verdict` tool only") is meaningless to a model with no tool
access - a provider-specific adapter layer would need its own JSON-mode
instruction appended (as this benchmark's harness does), not a change to
the shipped prompt file itself (out of scope here regardless -
`prompts/decision-agent/v1.md` was not modified).

---

## 3. Benchmarking

### Representative dataset (7 scenarios covering all four verdict states)

| # | Scenario | Path | Verdict produced |
|---|---|---|---|
| 1 | Transport timeout | Tier 0 | `BLOCKED` |
| 2 | Exact status match (200/200) | Tier 1 | `PASS` |
| 3 | Clean status mismatch, structured expectation (mocked) | Tier 2 / Claude (mock) | `FAIL` |
| 4 | Intent-over-exact-code, free-text expectation (mocked) | Tier 2 / Claude (mock) | `PASS` |
| 5 | Empty body, thin evidence (mocked) | Tier 2 / Claude (mock) | `MANUAL_REVIEW` |
| 6 | Same as #3, real model | Tier 2 / Ollama (real) | `FAIL` |
| 7 | Same as #4, real model | Tier 2 / Ollama (real) | `PASS` |
| 8 | Same as #5, real model | Tier 2 / Ollama (real) | `MANUAL_REVIEW` |
| 9 | Novel: rate-limit headers as evidence, real model | Tier 2 / Ollama (real) | Rejected - malformed JSON |
| 10 | Novel: 204-expected vs. 200-with-body, real model | Tier 2 / Ollama (real) | `PASS` (incorrectly - see section 5) |

All four required verdict states (`PASS`/`FAIL`/`BLOCKED`/`MANUAL_REVIEW`)
are represented, on both the deterministic and AI-assisted paths.

### Timing, prompt size, response size (real Ollama calls only - mocked calls have no real latency to report)

| Scenario | Wall time | Prompt (chars / tokens) | Response (chars / tokens) |
|---|---|---|---|
| #6 FAIL clean | 113.6s *(cold - includes ~17s model load)* | 4,534 / 1,069 | 319 / 82 |
| #7 PASS intent | 28.5s | 4,565 / 1,073 | 353 / 85 |
| #8 MANUAL_REVIEW thin | 25.0s | 4,524 / 1,056 | 353 / 89 |
| #9 Novel headers | 27.9s | 4,534 / 1,070 | 337 / 91 |
| #10 Novel 204 | 25.5s | 4,511 / 1,067 | 290 / 79 |
| **Average (warm calls, #7-10)** | **26.7s** | **4,534 / 1,067** | **333 / 86** |

Prompt size is dominated by the static system prompt (~4,150 of the
~4,534 chars is the fixed system prompt + few-shot examples; the
per-request evidence packet itself is small, ~300-400 chars). This
matches `docs/architecture/decision-agent-design.md` section 8's
recommendation to prompt-cache the static portion - not implemented
here (out of scope), but this benchmark is the first real measurement
confirming the static/dynamic size split that recommendation assumes.

### Decision path counts (this benchmark's 10-scenario set)

| Path | Count | % |
|---|---|---|
| Tier 0 (deterministic, no AI) | 1 | 10% |
| Tier 1 (deterministic, no AI) | 1 | 10% |
| Tier 2 (AI-assisted) | 8 | 80% |

**Caveat on this ratio:** this dataset was deliberately built to exercise
every verdict state and several Tier 2 edge cases, so it is not a
realistic sample of what a real test suite's Tier 0/1/2 split would look
like - `docs/architecture/decision-agent-design.md` section 1's premise
(most real-world API tests are simple status-code checks, so Tiers 0-1
should dominate in practice) is not something this small, deliberately
AI-heavy benchmark set can confirm or refute. A representative sample
from an actual test suite is needed to validate that premise - flagged
as a recommendation in section 8.

### Local inference performance (Ollama, llama3:latest, this machine)

- **Cold start:** ~17.3s one-time model load, included in the first
  call's 113.6s total.
- **Warm inference:** ~25-29s per call once the model is loaded, for a
  ~4,500-character prompt and a ~300-350-character JSON response.
- **Practical implication:** at ~27s/call, a batch of 50 Tier-2 test
  cases run sequentially against this local model would take
  **~22 minutes** of wall-clock AI time alone (excluding Tier 0/1, which
  are instant). This is the concrete number to weigh against
  `decision-agent-design.md` section 8's cheap-model-first cascade idea
  - a local model may be "free" in API cost but is not free in wall-clock
  time relative to a hosted Claude Haiku-class call, which is typically
  low single-digit seconds - not measured here, since no real Anthropic
  call was possible in this environment; stated as a general expectation
  to weigh against, not a benchmarked comparison.

---

## 4. Confidence calibration observations

Per the task's explicit instruction, **no new thresholds are proposed
here** - only an assessment of the existing `TRUST_CONFIG` values
against what this benchmark actually observed.

| `TRUST_CONFIG` value | Current | Observed against it | Assessment |
|---|---|---|---|
| `CONFIDENCE_THRESHOLD` (0.7) | Gates PASS/FAIL vs. MANUAL_REVIEW | Every real/mocked PASS/FAIL landed at 0.75-0.95 (well above); the one MANUAL_REVIEW case stayed at 0.3 (well below). **No sample in this benchmark landed near the 0.7 boundary.** | Cannot assess from this data whether 0.7 is well-calibrated - the benchmark didn't produce a borderline case. Needs a larger/more adversarial sample specifically targeting the 0.5-0.8 range before any recalibration decision. |
| `STRUCTURED_EXPECTATION_CAP` (0.95) | Caps confidence when `expected_status` is a real number | Scenario #10 (204-expected vs. 200-with-body) had a structured `expected_status`, was fully grounded (ratio 1.0), and the model was **wrong** - yet still capped at 0.95, the *highest* tier. | **Appears too permissive as currently scoped.** The cap is based purely on evidence *structure* (was there a number to compare against, was every cited fact traceable), not on whether the *conclusion* is consistent with that evidence. This benchmark demonstrates a case where both those structural conditions were fully satisfied and the verdict was still wrong. Not proposing a new number - flagging that the cap's current basis (structural grounding alone) has a demonstrated blind spot. |
| `FREE_TEXT_EXPECTATION_CAP` (0.75) | Caps confidence when only free-text `expected_result` existed | Scenario #7 (real) and mocked scenario #4 both landed exactly at the cap (0.75), both correctly judged. | Consistent behavior observed; no evidence either way on whether 0.75 itself is right - both observed cases were correct judgments, so the cap didn't need to catch an error here. |
| `PARTIAL_GROUNDING_CAP` (0.5) | Caps confidence when 0% < grounding ratio < 100% | Not exercised in this benchmark - every real/mocked evidence set was either fully grounded (ratio 1.0) or, in the pre-existing Task 4.4 test suite, fully ungrounded (ratio 0, different code path). | Untested against real model output in this benchmark. Task 4.4's synthetic tests already cover the mechanism; this benchmark didn't happen to produce a genuinely partial case from a real model. Worth a targeted future test. |
| `DECISIVE_CONFIDENCE_FLOOR` (0.3) | Rejects PASS/FAIL below this as `UNGROUNDED_VERDICT` | Not triggered - no real or mocked PASS/FAIL in this benchmark reported confidence below 0.3 (the one sub-0.3 case was a correctly-labeled MANUAL_REVIEW, which this check doesn't apply to). | Cannot assess from this data. |
| `UNGROUNDED_CONFIDENCE` (0.2) | Forced ceiling when 0% grounded | Not exercised by real model output in this benchmark (Task 4.4's synthetic tests cover the mechanism). | Untested against real model output here. |

**Headline calibration finding:** the confidence-capping mechanism is
well-verified structurally (Task 4.4's synthetic tests, this task's real
tests), but this benchmark surfaced the mechanism's actual **design
limit**, not a bug: capping evidence-grounded confidence still cannot
catch a case where the evidence is real and correctly cited but the
*conclusion drawn from it* is wrong. That is a semantic-consistency gap,
not a confidence-calibration gap, and is out of this task's scope to fix
(see section 8 recommendations).

---

## 5. Prompt v1 validation findings

Per the task's instruction, this section documents findings only -
`prompts/decision-agent/v1.md` was not modified.

### Finding 1: evidence-format compliance depends heavily on the few-shot examples

An early exploratory probe (system prompt with the six numbered rules
but *without* the three worked examples) produced evidence entries like
`"field: description"` - not tracing to any real evidence-packet field,
and not even attempting the `field: value` convention correctly. Once
the **full** system prompt (rules + all three worked examples, exactly
as shipped) was used, all 5 real benchmark calls produced correctly
`field: value`-formatted evidence with a 100% grounding ratio. **The
few-shot examples are doing real, load-bearing work for this model, not
decorative work** - this is a meaningful, positive finding about the
prompt's design, worth stating plainly rather than assuming.

### Finding 2: malformed tool response - reproduced, not hypothetical

Scenario #9 (rate-limit headers) produced a JSON response that ended
mid-structure:

```
...
"response_headers.retry-after: 30"
]
```

(missing the closing `}` for the evidence array and the root object).
`Validate AI Response Shape` correctly rejected this as
`INVALID_MODEL_RESPONSE` - the system behaved exactly as designed. This
is the first real (not synthetic) confirmation that the
malformed-response path actually fires against genuine model output, not
just hand-crafted test fixtures. Observed once in 5 calls (20% in this
tiny sample) - not enough calls to produce a reliable failure-rate
estimate, but enough to confirm the failure mode is real, not
theoretical.

### Finding 3: inconsistent reasoning - a verdict that contradicts its own stated reasoning

Scenario #10 is the most important finding in this report. The model's
full response:

```json
{
  "status": "PASS",
  "confidence": 0.95,
  "reasoning": "Expected 204 No Content, but the API returned 200 OK with
    a response body indicating successful deletion.",
  "evidence": ["expected_result: 204 No Content", "expected_status: 204",
    "actual_status: 200", "response_body.deleted: true"]
}
```

The `reasoning` field is a textbook description of a **contradiction**
("expected X, but got Y") - the kind of sentence that, in every one of
the prompt's own worked examples, precedes a `FAIL`. The model still
returned `status: "PASS"`. Every evidence entry is real, correctly
formatted, and correctly grounded (ratio 1.0) - the Trust Layer had no
structural signal to catch this, because there wasn't a *structural*
problem. This is a genuine reasoning failure by the model: it correctly
retrieved and cited the facts, and drew the wrong conclusion from them
anyway.

### Finding 4: unsupported evidence

Not observed in this benchmark's real calls - every evidence entry
across all 5 real responses traced correctly to the evidence packet
(grounding ratio 1.0 in every non-rejected case). Task 4.4's synthetic
test suite already covers this scenario (fabricated field references,
fabricated values) with a mocked model; this benchmark did not happen to
elicit it from the real model. Worth targeted future testing with a
more adversarial prompt (e.g. a response body containing text that
could plausibly be mistaken for an unrelated field name).

### Finding 5: ambiguous outputs

Scenario #8 (empty body, thin evidence) correctly resolved to
`MANUAL_REVIEW` with well-grounded, appropriately low-confidence (0.3)
output - the model handled genuine ambiguity exactly as Rule 3 and
Example 3 intend. No ambiguous-output failure was observed in this
benchmark.

---

## 6. Decision metrics (this benchmark run)

| Metric | Value |
|---|---|
| Tier 0 count | 1 |
| Tier 1 count | 1 |
| Tier 2 count | 8 (3 mocked, 5 real) |
| Average real-model response time | 26.7s (warm), 113.6s (cold, one-time) |
| Average prompt size | 4,534 chars / ~1,067 tokens |
| Average response size | 333 chars / ~86 tokens |
| Real-model malformed-response rate | 1/5 (20%) |
| Real-model grounding ratio (non-rejected responses) | 4/4 at 1.0 (100%) |
| Real-model semantically-wrong-despite-grounded rate | 1/4 (25% of non-rejected responses) |
| Existing regression suite | 82/82 passing (zero regressions from this task) |

---

## 7. Known limitations (for `AI_MEMORY.md`/`README.md`, summarized here first)

1. **Semantic consistency is not checked.** The Trust Layer validates
   structure (shape, grounding) but not whether the verdict logically
   follows from the cited evidence. Demonstrated, not hypothetical
   (section 5, Finding 3).
2. **Local-model JSON conformance is not guaranteed.** Unlike Claude's
   forced `tool_choice`, a non-tool-calling local model's structured
   output is requested via prompt instruction only, and failed to parse
   in 1 of 5 real calls in this benchmark.
3. **Real Anthropic behavior remains completely unverified.** Every task
   from 4.1 onward, including this one, has tested the Claude path only
   against scripted/mocked responses. This is the single largest
   unclosed verification gap across the whole Decision Engine.
4. **Confidence threshold calibration is inconclusive**, not validated.
   This benchmark's samples didn't land near the 0.7/0.3 boundaries, so
   those specific thresholds remain unverified placeholders, not
   confirmed-good or confirmed-bad.
5. **Tier 0/1/2 split ratio from this benchmark is not representative**
   - the dataset was built to exercise edge cases and verdict-state
   diversity, not to mirror a real test suite's natural distribution.
6. **Live n8n execution remains untested.** Every verification across
   Tasks 4.1-4.5 has run via extracted `jsCode` in a script harness, not
   inside an actual n8n instance. Node parameter shapes (the `httpRequest`
   node's exact fields, credential wiring) remain unverified in situ.

---

## 8. Recommendations before Task 5 (Documentation Agent)

1. **Do not treat `STRUCTURED_EXPECTATION_CAP` (0.95) as validated** -
   this benchmark demonstrated a real case where a fully-grounded,
   structured-expectation verdict was still wrong. Whatever Documentation
   Agent/Jira Agent build on top of `next_action: "create_jira"` should
   assume a small but real false-positive rate exists at high confidence,
   not treat 0.9+ confidence as a correctness guarantee.
2. **Prioritize a real n8n + real Anthropic credential verification
   pass** before Milestone 1 is called fully done - it's the largest gap
   this report couldn't close, and it compounds with every task built on
   top of it (now five).
3. **A semantic-consistency check (reasoning-vs-verdict coherence) is a
   well-scoped, concrete next capability** for whichever future task
   picks up hallucination/trust work again - this report gives it a real
   reproduced example (section 5, Finding 3) to design and test against,
   rather than a hypothetical one.
4. **If local-model support becomes a real requirement** (not just a
   verification exercise), the two-node seam identified in section 2
   (`Build Claude API Request` + `Validate AI Response Shape`) is exactly
   where a second provider adapter would go - additive, no redesign of
   anything downstream.
5. **Before relying on Tier 0/1/2 ratio assumptions for cost planning**,
   benchmark against a real, representative test suite sample - this
   report's 10%/10%/80% split is an artifact of a deliberately AI-heavy
   test dataset, not a production estimate.
