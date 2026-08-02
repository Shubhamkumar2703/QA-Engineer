# Self-Review: Task 4.0 — Decision Agent Foundations

Reviewer: implementer, in senior-engineer-reviewing-a-PR mode.
Scope: ADR 005, `docs/contracts/decision-contract.md`,
`prompts/decision-agent/v1.md`, and the amendment to
`docs/architecture/milestone-1.md` section 5. Nothing here has been
implemented as a workflow yet (that's Task 4.1+) - this review is about
whether the *foundations* Task 4.1-4.5 will be built on are solid.

Findings only. Where something is fixable at zero cost and
uncontroversial, I fixed it inline before finalizing 4.0 rather than
listing it as a finding (noted where that happened). Everything else is
listed for the task tree you gave, not silently patched.

---

## 1. Real gaps

**The 0.7 / 0.8 confidence thresholds in `decision-contract.md` are
placeholders, not calibrated values.** No real model has been run
against real evidence yet - these numbers came from reasoning about what
*should* separate "trust this autonomously" from "needs a human," not
from measuring what a real model's confidence scores actually look like
in practice. There is a real risk they're miscalibrated in either
direction: too low, and low-quality verdicts get auto-filed as Jira
tickets; too high, and every borderline case floods `flag_for_review`,
defeating the automation's purpose. **This needs revisiting once Task
4.3 produces real model output to calibrate against** - treat the
current numbers as a starting hypothesis, not a settled decision.

**The evidence-grounding check has a concept but no algorithm.** Both
the prompt (Rule 4) and `decision-agent-design.md` section 7 say every
`evidence[]` entry must be "grounded" in the evidence block, and an
ungrounded entry should downgrade the verdict to `MANUAL_REVIEW`. What
isn't specified: *how* a deterministic Code node actually checks this. A
naive substring match breaks on paraphrasing (`"response_body.created:
true"` vs. `"the account was created"` vs. `"created=true"` all express
the same fact differently). This is exactly the kind of thing that's
easy to hand-wave in a design document and hard to actually implement
correctly - it needs a concrete algorithm decision (regex against known
field paths? a second, cheaper model call to verify grounding? a
stricter output schema that forces evidence into `{field, value}` pairs
instead of free strings, so grounding becomes an exact lookup instead of
fuzzy matching?) **before Task 4.4 (Confidence & Hallucination Guards)
can be built**, not during it as an afterthought. My own inclination is
the schema-based fix (structured `{field, value}` evidence instead of
free strings) since it turns a fuzzy-matching problem into an exact one,
but that's a recommendation for 4.4 to make deliberately, not something
this review is deciding.

**No design yet for what happens when the model call itself fails** (API
error, rate limit, timeout calling Anthropic - as distinct from the
model returning a schema-invalid response, which *is* covered). This is
a genuine gap in `decision-contract.md`'s anticipated error codes: there
is no `AI_SERVICE_UNAVAILABLE`-shaped code, and more importantly, no
decision about whether this *should* be an ERROR payload at all, or
whether it deserves its own status - conceptually it's closer to a
transport failure (BLOCKED - "we couldn't get an answer") than to a data-
quality error, but the current framework only has BLOCKED wired to
`transport.status_code === null`, which describes the HTTP call to the
API-under-test, not a call to the AI provider. I deliberately did not
patch this into `decision-contract.md` with a guessed answer, since it
affects the tier framework's conceptual shape (does a 5th pseudo-state
exist, or does a failed AI call retry-then-degrade to `MANUAL_REVIEW`
with `decision_basis.model_version` still populated but confidence
forced to 0?) and deserves real thought during Task 4.1/4.3, not a
rushed addition here.

**The few-shot examples in `prompts/decision-agent/v1.md` are entirely
untested against a real model.** They're hypothetical, written to
illustrate the three behaviors the prompt's rules describe (clean
contradiction, intent-over-exact-code, correctly abstaining under thin
evidence) - there's no evidence yet that a real Claude call with this
system prompt actually produces output matching this quality or
calibration. **Task 4.3 (AI Evaluation Node) needs to run real test
cases through a real model and check the output against these examples'
spirit**, not assume the prompt works because it reads well.

## 2. Deliberate tradeoffs (restated here so they don't look like oversights)

- **Every status-code mismatch routes to Tier 2 (AI), even ones that
  could plausibly skip it** (e.g. expected 200, got 500, pure status-code
  test with no body-content language - arguably as mechanical as Tier 1
  in the other direction). This was a deliberate choice, not a missed
  optimization: routing every FAIL through the model means every FAIL
  gets a human-readable explanation attached, which matters because
  FAILs are the verdicts that become Jira ticket descriptions a person
  actually reads. A "deterministic FAIL" tier would save cost but
  produce templated, less useful ticket text. Worth revisiting only if
  Task 4.3's real-world cost numbers make it necessary - not a bug to fix
  now.
- **`next_action: "flag_for_review"` is shared by both `MANUAL_REVIEW`
  verdicts and low-confidence `FAIL` verdicts.** These are different
  situations (couldn't judge at all, vs. judged FAIL but not confidently
  enough to auto-file), but `next_action` only needs to answer "where does
  this route," and `verdict.status` already disambiguates for anyone
  triaging the queue. Collapsing them in `next_action` is intentional,
  not a loss of information.
- **Few-shot examples live inside the same versioned file as the
  instructions**, not a separate `examples-v1.md`. Chosen because
  `prompt_version` is the one field tracking "what produced this
  verdict" (`decision_basis.prompt_version`) - splitting examples out
  would mean a prompt change and an examples change could drift out of
  sync under one version number. Worth reconsidering only if examples
  end up churning much faster than instructions in practice.

## 3. A footgun, accepted rather than fixed

`error-payload.md`'s ERROR shape uses `status: "ERROR"` at the top
level; a valid Decision Contract's judgment lives at `verdict.status`
(`PASS`/`FAIL`/`BLOCKED`/`MANUAL_REVIEW`) - two different fields both
named `status`, one level apart. This is called out explicitly in
`decision-contract.md`'s "Consumer" section specifically because it's a
real risk for whoever writes the Documentation/Jira agents: reading
`item.status` and expecting a verdict value, instead of first checking
`item.status === 'ERROR'` the way every other contract requires. Renaming
either field would be more invasive than it's worth (every contract in
this project already uses top-level `status: "ERROR"` as the universal
check) - documenting the collision prominently is the right level of fix
for now, not a schema change.

## 4. Scope check on ADR 005's claim

ADR 005 asserts `NOT_RUN` cannot occur *in the Decision Agent's own
output* - worth confirming this claim is scoped correctly and not
overreaching. It is: the ADR only changes the Decision Agent's `status`
enum, not any system-wide concept of "not run." A test case skipped
entirely upstream (e.g. a future Planner deciding not to route it) never
reaches the Decision Agent at all, so a system-level "not run" concept
could still exist elsewhere (a batch summary, Documentation Agent) - ADR
005 doesn't claim otherwise and shouldn't be read as closing that door.

## 5. What's solid

- The tier funnel's boundary condition (`transport.status_code ===
  null`) is a genuine strength worth calling out again: it's not a
  heuristic or a string-matching guess, it's a guarantee
  `normalized-response-contract.md` already makes, so Tier 0's trigger
  is a one-line, unambiguous check with no drift risk.
- The prompt's Rule 5 ("confidence reflects how directly the evidence
  answers the question, not how confident you feel... do not use
  confidence as a hedge in place of choosing MANUAL_REVIEW") directly
  targets the most common failure mode of asking a model to self-report
  confidence - explicitly naming the failure mode in the instructions,
  rather than hoping the model infers it, is the right level of
  explicitness for a judgment task with real downstream consequences
  (Jira ticket creation).
- `decision_basis` gives every verdict an audit trail for "was this free
  or did it cost a model call," which makes both the cost story in
  section 8 of the design doc and any future hallucination post-mortem
  answerable from the data itself rather than from memory.

---

## Recommendations, sequenced against your task tree

- **Before 4.1 (workflow):** none blocking - the contract and ADR are
  stable enough to build the workflow skeleton against.
- **Before/during 4.3 (AI Evaluation Node):** decide the AI-service-
  failure handling (section 1) before wiring the actual model call, and
  run the three few-shot examples (plus a handful of real test cases)
  against a real model to sanity-check the prompt before trusting it in
  the pipeline.
- **Before/during 4.4 (Confidence & Hallucination Guards):** decide the
  grounding-check algorithm concretely (section 1) - my recommendation
  is structured `{field, value}` evidence pairs over free-string
  matching, but that's 4.4's call to make, not this review's.
- **After 4.1-4.5 produce real verdicts:** revisit the 0.7/0.8 confidence
  thresholds against real calibration data rather than treating them as
  final.

Nothing above blocks starting Task 4.1.
