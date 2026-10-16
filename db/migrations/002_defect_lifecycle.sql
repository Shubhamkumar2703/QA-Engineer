-- Defect lifecycle foundation: deduplicated drafts, explicit human decisions, audit history.
-- This migration is additive; it does not change the existing API test pipeline.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS defect_drafts (
    defect_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key    TEXT NOT NULL UNIQUE,
    fingerprint        TEXT NOT NULL,
    test_id             TEXT NOT NULL,
    title               TEXT NOT NULL,
    severity            TEXT NOT NULL CHECK (severity IN ('critical', 'high', 'medium', 'low')),
    endpoint            TEXT,
    http_method         TEXT,
    expected_result     TEXT NOT NULL,
    actual_result       TEXT NOT NULL,
    reproduction_steps  JSONB NOT NULL DEFAULT '[]'::jsonb
                         CHECK (jsonb_typeof(reproduction_steps) = 'array'),
    evidence            JSONB NOT NULL DEFAULT '{}'::jsonb
                         CHECK (jsonb_typeof(evidence) = 'object'),
    status              TEXT NOT NULL DEFAULT 'PENDING_APPROVAL'
                         CHECK (status IN ('PENDING_APPROVAL', 'APPROVED', 'REJECTED', 'SUBMITTED', 'DUPLICATE')),
    duplicate_of        UUID REFERENCES defect_drafts(defect_id),
    reviewer            TEXT,
    review_note         TEXT,
    submitted_reference TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    reviewed_at         TIMESTAMPTZ,
    submitted_at        TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (
        (status = 'PENDING_APPROVAL' AND reviewed_at IS NULL AND submitted_at IS NULL)
        OR status <> 'PENDING_APPROVAL'
    ),
    CHECK (
        status <> 'SUBMITTED' OR (reviewed_at IS NOT NULL AND submitted_at IS NOT NULL)
    )
);

-- Prevent multiple active drafts for the same normalized defect fingerprint.
-- Rejected drafts do not block a later, intentionally re-proposed defect.
CREATE UNIQUE INDEX IF NOT EXISTS uq_defect_drafts_active_fingerprint
    ON defect_drafts (fingerprint)
    WHERE status IN ('PENDING_APPROVAL', 'APPROVED', 'SUBMITTED');

CREATE INDEX IF NOT EXISTS idx_defect_drafts_status_created
    ON defect_drafts (status, created_at DESC);

CREATE TABLE IF NOT EXISTS defect_audit_events (
    event_id       BIGSERIAL PRIMARY KEY,
    defect_id      UUID NOT NULL REFERENCES defect_drafts(defect_id),
    event_type     TEXT NOT NULL CHECK (event_type IN (
        'DRAFT_CREATED', 'DUPLICATE_DETECTED', 'APPROVED', 'REJECTED',
        'SUBMISSION_REQUESTED', 'SUBMITTED', 'SUBMISSION_FAILED'
    )),
    actor          TEXT NOT NULL,
    details        JSONB NOT NULL DEFAULT '{}'::jsonb
                     CHECK (jsonb_typeof(details) = 'object'),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_defect_audit_events_defect_time
    ON defect_audit_events (defect_id, created_at);

-- The workflow must use a transaction for: insert draft + DRAFT_CREATED event.
-- Approval/rejection must use a conditional UPDATE where status = PENDING_APPROVAL
-- and append the corresponding audit event in the same transaction.
-- A unique-index conflict on active fingerprint must be treated as a duplicate,
-- not as permission to create another draft.
