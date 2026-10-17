# Defect lifecycle: duplicate detection and human review

## Implementation status

- **Database lifecycle operations:** implemented in migrations 002 and 003.
- **Regression checks:** SQL test script added at `tests/sql/defect_lifecycle.sql`.
- **n8n wiring and reviewer HTTP endpoints:** not yet wired or integration-tested.
- **Jira submission:** not implemented; the submission guard only records an audit event after confirming APPROVED state.

The original API testing pipeline and workflow 07 remain unchanged. Treat this as a database-backed lifecycle service foundation, not a finished operational approval UI.

## Lifecycle

```text
Validated Jira Draft Contract
    -> normalize stable defect fields + derive idempotency key/fingerprint
    -> create_defect_draft(...)
         -> created: PENDING_APPROVAL + DRAFT_CREATED
         -> existing: same idempotency key returns prior draft
         -> duplicate: active fingerprint match + DUPLICATE_DETECTED audit
    -> review_defect_draft(id, approve|reject, reviewer, note)
         -> conditional PENDING_APPROVAL transition + audit event
         -> stale/second review returns conflict
    -> request_defect_submission(id)
         -> APPROVED only; records SUBMISSION_REQUESTED
         -> does not call Jira or mark the draft SUBMITTED
```

## Database operations

Apply migrations in order:

1. `db/migrations/002_defect_lifecycle.sql`
2. `db/migrations/003_defect_lifecycle_functions.sql`

The functions return JSONB outcome envelopes for easy orchestration by n8n:

- `create_defect_draft(...)` validates inputs, persists the draft and creation event atomically, and distinguishes idempotent retries from duplicate fingerprints.
- `review_defect_draft(defect_id, action, reviewer, note)` accepts only `approve` or `reject`, requires reviewer identity, conditionally updates only pending drafts, and writes the audit event in the same transaction.
- `request_defect_submission(defect_id, actor)` independently enforces APPROVED state and records submission intent only. It intentionally does not integrate with Jira.

The active-fingerprint partial unique index is the concurrency guard. A rejected draft is no longer active, so a later proposal may be created intentionally. Idempotency keys must be unique per creation request; callers should reuse the same key for retries.

## Fingerprint and idempotency

The caller must supply a stable SHA-256 fingerprint over canonical, normalized fields. Suggested inputs: normalized endpoint, HTTP method, test ID, and a stable failure signature from expected/actual outcomes and status/error identifiers. Exclude timestamps, request IDs, latency, and full response bodies. The idempotency key is separate and represents a single logical create request.

Do not rely on a SELECT-before-INSERT duplicate check. The partial unique index is the final guard against racing inserts.

## Human review contract

- Only `PENDING_APPROVAL` drafts can be reviewed.
- Reviewer identity and timestamp are required.
- A stale or second decision must not overwrite the first decision.
- Rejected drafts cannot pass the submission guard.
- Any future submission adapter must call the guard independently; hiding an approval control is not a security boundary.

## Audit requirements

The database records draft creation, duplicate detection, approval/rejection, and submission intent. A future Jira adapter must additionally record submission success/failure and update status to SUBMITTED only after a confirmed provider result. Never store credentials or secrets in defect evidence or audit details.

## Regression tests

Run against a disposable PostgreSQL database after applying both migrations:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/sql/defect_lifecycle.sql
```

The test is wrapped in a transaction and rolls back fixtures. It checks creation, idempotent retry, duplicate fingerprint handling, single active draft, approval, stale-decision rejection, submission guard, and audit events. It has been committed but has **not** been executed against a live PostgreSQL instance in this environment.

## Remaining integration work

1. Wire workflow 07's eligible Jira Draft Contract output to a separate lifecycle workflow.
2. Derive and validate the canonical fingerprint/idempotency key before calling the database functions.
3. Add authenticated review endpoints or an approval UI for approve/reject; never trust a reviewer name supplied without authentication.
4. Add integration tests using PostgreSQL and n8n, including concurrent duplicate attempts.
5. Implement Jira submission only after approval and record provider success/failure. No live Jira API call is included now.
