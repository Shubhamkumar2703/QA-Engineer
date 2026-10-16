-- Database regression checks for the defect lifecycle functions.
-- Run after migrations 002 and 003:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/sql/defect_lifecycle.sql
-- All fixture rows/events are rolled back at the end.
BEGIN;

DO $$
DECLARE
    v_first JSONB;
    v_retry JSONB;
    v_duplicate JSONB;
    v_id UUID;
    v_review JSONB;
    v_count INTEGER;
BEGIN
    v_first := create_defect_draft(
        'test-idempotency-001', 'test-fingerprint-001', 'QA-LC-001',
        'Expected 401 but received 200', 'high', 'https://api.example.test/private',
        'GET', 'HTTP 401', 'HTTP 200', '["send GET request"]'::jsonb,
        '{"status":200}'::jsonb, 'sql-test'
    );
    IF v_first->>'outcome' <> 'created' THEN
        RAISE EXCEPTION 'Expected created outcome, got %', v_first->>'outcome';
    END IF;
    v_id := (v_first->'defect'->>'defect_id')::UUID;

    v_retry := create_defect_draft(
        'test-idempotency-001', 'test-fingerprint-001', 'QA-LC-001',
        'Expected 401 but received 200', 'high', 'https://api.example.test/private',
        'GET', 'HTTP 401', 'HTTP 200', '["send GET request"]'::jsonb,
        '{"status":200}'::jsonb, 'sql-test'
    );
    IF v_retry->>'outcome' <> 'existing' THEN
        RAISE EXCEPTION 'Idempotent retry must return existing draft';
    END IF;

    v_duplicate := create_defect_draft(
        'test-idempotency-002', 'test-fingerprint-001', 'QA-LC-002',
        'Same defect, different test run', 'high', 'https://api.example.test/private',
        'GET', 'HTTP 401', 'HTTP 200', '["send GET request"]'::jsonb,
        '{"status":200}'::jsonb, 'sql-test'
    );
    IF v_duplicate->>'outcome' <> 'duplicate' THEN
        RAISE EXCEPTION 'Expected duplicate outcome, got %', v_duplicate->>'outcome';
    END IF;

    SELECT count(*) INTO v_count FROM defect_drafts
     WHERE fingerprint = 'test-fingerprint-001'
       AND status IN ('PENDING_APPROVAL', 'APPROVED', 'SUBMITTED');
    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected exactly one active draft, found %', v_count;
    END IF;

    v_review := review_defect_draft(v_id, 'approve', 'reviewer@example.test', 'Verified evidence');
    IF v_review->>'outcome' <> 'approved' THEN
        RAISE EXCEPTION 'Expected approved outcome';
    END IF;

    BEGIN
        PERFORM review_defect_draft(v_id, 'reject', 'other-reviewer@example.test', 'Conflicting decision');
        RAISE EXCEPTION 'Second review should have been rejected';
    EXCEPTION WHEN SQLSTATE '40001' THEN
        NULL;
    END;

    PERFORM request_defect_submission(v_id, 'sql-test');

    BEGIN
        PERFORM request_defect_submission(gen_random_uuid(), 'sql-test');
        RAISE EXCEPTION 'Unknown draft should not pass submission guard';
    EXCEPTION WHEN SQLSTATE 'P0002' THEN
        NULL;
    END;

    -- A separate draft can be rejected, and rejection must block submission.
    v_first := create_defect_draft(
        'test-idempotency-003', 'test-fingerprint-002', 'QA-LC-003',
        'Unexpected response content', 'medium', 'https://api.example.test/items',
        'GET', 'JSON object', 'HTML page', '["send GET request"]'::jsonb,
        '{"content_type":"text/html"}'::jsonb, 'sql-test'
    );
    v_id := (v_first->'defect'->>'defect_id')::UUID;
    v_review := review_defect_draft(v_id, 'reject', 'reviewer@example.test', 'Expected behavior was clarified');
    IF v_review->>'outcome' <> 'rejected' THEN
        RAISE EXCEPTION 'Expected rejected outcome';
    END IF;

    BEGIN
        PERFORM request_defect_submission(v_id, 'sql-test');
        RAISE EXCEPTION 'Rejected draft must not pass submission guard';
    EXCEPTION WHEN SQLSTATE '42501' THEN
        NULL;
    END;

    SELECT count(*) INTO v_count FROM defect_audit_events
     WHERE defect_id = v_id AND event_type IN ('DRAFT_CREATED', 'REJECTED');
    IF v_count <> 2 THEN
        RAISE EXCEPTION 'Expected draft creation and rejection audit events, found %', v_count;
    END IF;
END;
$$;

ROLLBACK;
