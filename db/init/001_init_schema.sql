-- Milestone 1 logging schema
-- One row per workflow execution, one row per test-case decision,
-- and a small table for the duplicate-ticket check.

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- provides gen_random_uuid()

CREATE TABLE IF NOT EXISTS runs (
    run_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_file      TEXT NOT NULL,          -- name of the uploaded test script
    workflow_version TEXT,
    repo_commit      TEXT
);

CREATE TABLE IF NOT EXISTS decisions (
    id               SERIAL PRIMARY KEY,
    run_id           UUID NOT NULL REFERENCES runs(run_id),
    test_id          TEXT NOT NULL,
    description      TEXT,
    steps            TEXT,
    expected_result  TEXT,
    actual_result    TEXT,
    status           TEXT NOT NULL CHECK (status IN ('PASS', 'FAIL', 'BLOCKED', 'NOT_RUN')),
    confidence       NUMERIC(3,2),
    reasoning        TEXT,
    evidence         JSONB,
    next_action      TEXT CHECK (next_action IN ('write_report', 'create_jira', 'update_jira', 'none')),
    verification_type TEXT,
    prompt_version   TEXT,
    model_version    TEXT,
    tester           TEXT DEFAULT 'AI-Agent',
    jira_key         TEXT,
    human_verdict    TEXT CHECK (human_verdict IN ('PASS', 'FAIL', 'BLOCKED', 'NOT_RUN', 'REJECTED') OR human_verdict IS NULL),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_decisions_test_id ON decisions(test_id);
CREATE INDEX IF NOT EXISTS idx_decisions_run_id ON decisions(run_id);

-- Tracks one open ticket per test_id — this is what the Jira Agent's
-- duplicate check queries before drafting a new ticket.
CREATE TABLE IF NOT EXISTS jira_tickets (
    test_id     TEXT PRIMARY KEY,
    jira_key    TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
