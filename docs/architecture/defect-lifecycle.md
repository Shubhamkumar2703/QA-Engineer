# Defect lifecycle: duplicate detection and human review

## Status

Implementation plan and persistence contract. The SQL foundation is introduced by
`db/migrations/002_defect_lifecycle.sql`. The n8n workflow/API handlers must be
wired and integration-tested before this feature is described as operational.

## Goals

- Preserve workflow 07's current responsibility: produce a deterministic Jira Draft Contract.
- Create a persisted defect draft with a stable idempotency key and normalized fingerprint.
- Prevent duplicate active drafts even when two executions race.
- Require an explicit human decision before any external submission.
- Persist an append-only audit trail for draft creation, duplicate detection, review, and submission attempts.
- Make reject a terminal review decision; never route a rejected draft to submission.

## Lifecycle

```text
Report Contract
    -> Jira Draft Contract (workflow 07)
    -> Validate + normalize defect fields
    -> Calculate fingerprint
    -> PostgreSQL transaction
         -> existing active fingerprint? yes -> record duplicate event / link existing draft
         -> no -> insert PENDING_APPROVAL draft + DRAFT_CREATED event
    -> Human review
         -> Approve -> conditional PENDING_APPROVAL -> APPROVED + audit event
         -> Reject  -> conditional PENDING_APPROVAL -> REJECTED + audit event
    -> Submission adapter accepts APPROVED only
    -> Successful provider response -> SUBMITTED + audit event
```

## Fingerprint and idempotency

Fingerprint inputs should be normalized endpoint (lowercase host, normalized path),
HTTP method, test ID, and a stable failure signature. The failure signature should
use the expected/actual outcome and a stable error/status identifier, not timestamps,
request IDs, latency, or full response bodies. Hash a canonical JSON serialization
with SHA-256. Keep the idempotency key separate: it protects retries of the same
draft-creation request; the fingerprint identifies equivalent active defects.

Do not rely on a prior SELECT alone for deduplication. Concurrent runs can both
observe no match. The unique partial index on active fingerprints is the final
race-safe guard. On a uniqueness conflict, fetch the existing active draft and
record a duplicate-detection audit event.

## Human approval contract

- Only a draft whose current status is `PENDING_APPROVAL` can be reviewed.
- The action must be exactly `approve` or `reject`.
- Reviewer identity and decision timestamp are required.
- Use a conditional update (`WHERE defect_id = $1 AND status = 'PENDING_APPROVAL'`) and check that exactly one row changed.
- A second or stale decision returns a conflict and must not overwrite the first decision.
- Rejection requires an optional reason and never submits to Jira.
- The submission adapter must independently enforce `status = 'APPROVED'`; hiding a UI button is not a security boundary.

## Audit requirements

Append events for draft creation, duplicate detection, approval/rejection, submission requested,
submission success, and submission failure. Do not update or delete previous audit events.
Store actor, timestamp, and relevant safe metadata. Never store API credentials or secrets.

## Safety and integration boundary

This migration creates persistence tables and constraints only. It does not by itself create
an HTTP review interface, connect n8n to these tables, or implement Jira submission. The
existing API test pipeline remains unchanged. Implement the lifecycle as a separate workflow
and only connect it after the current Jira Draft Contract output has been validated.
