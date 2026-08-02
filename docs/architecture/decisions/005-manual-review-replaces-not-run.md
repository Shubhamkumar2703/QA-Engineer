# 005 - MANUAL_REVIEW replaces NOT_RUN as a Decision Agent verdict state

## Status
Accepted

## Context

`docs/architecture/milestone-1.md` section 5 and ADR 004 specify the
Decision Agent's `status` field as one of `PASS | FAIL | BLOCKED |
NOT_RUN`. Designing the Decision Agent's actual reasoning process
(`docs/architecture/decision-agent-design.md`) surfaced that `NOT_RUN`
cannot occur in practice: the Decision Agent only ever receives a
Normalized Response Contract (`docs/contracts/normalized-response-contract.md`),
which by construction only exists for a test case that already ran
through the HTTP Executor and Response Normalizer. There is no path by
which an already-executed test case reaches the Decision Agent in a
"not run" state - a test that was never routed to execution never
produces the input this workflow consumes at all. Keeping `NOT_RUN` in
the enum is either dead code or, worse, a state some future maintainer
reaches for under the wrong circumstances because it's the only
"something's off" option available.

What the Decision Agent's reasoning design actually needs is a state
that does not exist in the original four: a real HTTP response was
received, the AI attempted a genuine judgment, but confidence in that
judgment fell below the threshold to trust it autonomously (thin
evidence, an ungrounded model claim, a hallucination guard rejecting the
model's output - see `docs/architecture/decision-agent-design.md`
sections 3 and 7). This is a live, in-the-loop escape hatch, not a
pre-execution state, and it has no home in the current four values.

## Decision

Replace `NOT_RUN` with `MANUAL_REVIEW` in the Decision Agent's `status`
enum. The four verdict states become:

- `PASS` - a real response was received and satisfies `expected`.
- `FAIL` - a real response was received and contradicts `expected`.
- `BLOCKED` - no real response was ever received (`transport.status_code
  === null` on the Normalized Response Contract) - a system/transport
  failure, never a statement about the API under test. Unchanged from
  the original four.
- `MANUAL_REVIEW` - a real response was received, the Decision Agent
  attempted a judgment, but confidence was too low to trust it
  autonomously, or a hallucination guard rejected the model's output.
  Replaces `NOT_RUN`.

This also resolves a related ambiguity in the same enum:
`next_action: "update_jira"` is documented in milestone-1.md section 5,
but the Jira Agent's own responsibility description says *it* performs
the duplicate-ticket check and decides comment-vs-create - the Decision
Agent has no reliable way to know whether an open ticket already exists
for a given `test_id` at verdict time. `update_jira` is dropped from the
Decision Agent's `next_action` vocabulary; the Jira Agent (Task 4+, not
yet built) is solely responsible for choosing between creating a new
ticket and commenting on an existing one, using its own duplicate check,
after receiving `create_jira`. A new `next_action` value,
`flag_for_review`, is added to pair with `MANUAL_REVIEW` - without it,
`MANUAL_REVIEW` would have no differentiated next step and would
collapse into `none` (BLOCKED's value), which would silently discard the
"a human needs to look at this" signal `MANUAL_REVIEW` exists to carry.

`next_action` is therefore one of `write_report | create_jira |
flag_for_review | none`.

## Consequences

- `docs/architecture/milestone-1.md` section 5's Decision Agent output
  contract is updated to match (`status` and `next_action` enums).
- `docs/contracts/decision-contract.md` (new, Task 4.0) documents this
  as the shipped contract shape - it never carried `NOT_RUN` or
  `update_jira` in the first place.
- The Documentation Agent (Task 4+) needs to handle `MANUAL_REVIEW` as a
  distinct report row state, not fold it into `BLOCKED`'s handling -
  they mean different things (system failure vs. low-confidence
  judgment) and a human triaging a report benefits from telling them
  apart.
- ADR 004's core decision (always structured JSON, never prose) is
  unaffected - this ADR only changes which values are valid inside that
  structure, consistent with ADR 004's own shape.
- Per `docs/architecture/repository-design.md` section 7, this ADR
  supersedes the relevant portion of `milestone-1.md` section 5's
  original enum rather than that document being edited as if the
  original enum were never there - the milestone doc is updated to
  match, and this ADR is the record of why.
