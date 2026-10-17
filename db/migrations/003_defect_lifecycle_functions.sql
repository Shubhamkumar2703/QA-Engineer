-- Transactional defect lifecycle operations.
-- Apply after 002_defect_lifecycle.sql. Functions return JSONB so n8n can use
-- a single parameterized SELECT per operation and keep writes atomic.

CREATE OR REPLACE FUNCTION create_defect_draft(
    p_idempotency_key TEXT,
    p_fingerprint TEXT,
    p_test_id TEXT,
    p_title TEXT,
    p_severity TEXT,
    p_endpoint TEXT,
    p_http_method TEXT,
    p_expected_result TEXT,
    p_actual_result TEXT,
    p_reproduction_steps JSONB DEFAULT '[]'::jsonb,
    p_evidence JSONB DEFAULT '{}'::jsonb,
    p_actor TEXT DEFAULT 'n8n'
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft defect_drafts%ROWTYPE;
    v_inserted BOOLEAN := FALSE;
BEGIN
    IF COALESCE(trim(p_idempotency_key), '') = '' OR
       COALESCE(trim(p_fingerprint), '') = '' OR
       COALESCE(trim(p_test_id), '') = '' OR
       COALESCE(trim(p_title), '') = '' OR
       p_severity NOT IN ('critical', 'high', 'medium', 'low') OR
       p_expected_result IS NULL OR p_actual_result IS NULL OR
       jsonb_typeof(COALESCE(p_reproduction_steps, '[]'::jsonb)) <> 'array' OR
       jsonb_typeof(COALESCE(p_evidence, '{}'::jsonb)) <> 'object' THEN
        RAISE EXCEPTION 'Invalid defect draft payload' USING ERRCODE = '22023';
    END IF;

    -- Idempotent retry: same key returns the original result.
    SELECT * INTO v_draft FROM defect_drafts WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'outcome', CASE WHEN v_draft.status = 'DUPLICATE' THEN 'duplicate' ELSE 'existing' END,
            'defect', to_jsonb(v_draft)
        );
    END IF;

    INSERT INTO defect_drafts (
        idempotency_key, fingerprint, test_id, title, severity, endpoint,
        http_method, expected_result, actual_result, reproduction_steps, evidence
    ) VALUES (
        p_idempotency_key, p_fingerprint, p_test_id, p_title, p_severity, p_endpoint,
        p_http_method, p_expected_result, p_actual_result,
        COALESCE(p_reproduction_steps, '[]'::jsonb), COALESCE(p_evidence, '{}'::jsonb)
    )
    ON CONFLICT DO NOTHING
    RETURNING * INTO v_draft;

    v_inserted := FOUND;
    IF v_inserted THEN
        INSERT INTO defect_audit_events (defect_id, event_type, actor, details)
        VALUES (v_draft.defect_id, 'DRAFT_CREATED', COALESCE(NULLIF(trim(p_actor), ''), 'n8n'),
                jsonb_build_object('test_id', p_test_id, 'fingerprint', p_fingerprint));
        RETURN jsonb_build_object('outcome', 'created', 'defect', to_jsonb(v_draft));
    END IF;

    -- Resolve an idempotency-key race before treating it as a new duplicate.
    SELECT * INTO v_draft FROM defect_drafts WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN jsonb_build_object('outcome', 'existing', 'defect', to_jsonb(v_draft));
    END IF;

    -- The active-fingerprint unique index is the race-safe duplicate guard.
    SELECT * INTO v_draft
      FROM defect_drafts
     WHERE fingerprint = p_fingerprint
       AND status IN ('PENDING_APPROVAL', 'APPROVED', 'SUBMITTED')
     ORDER BY created_at
     LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Draft insert conflicted but no matching draft was found'
            USING ERRCODE = '40001';
    END IF;

    INSERT INTO defect_audit_events (defect_id, event_type, actor, details)
    VALUES (v_draft.defect_id, 'DUPLICATE_DETECTED', COALESCE(NULLIF(trim(p_actor), ''), 'n8n'),
            jsonb_build_object('attempted_idempotency_key', p_idempotency_key,
                               'fingerprint', p_fingerprint, 'test_id', p_test_id));

    RETURN jsonb_build_object('outcome', 'duplicate', 'defect', to_jsonb(v_draft));
END;
$$;

CREATE OR REPLACE FUNCTION review_defect_draft(
    p_defect_id UUID,
    p_action TEXT,
    p_reviewer TEXT,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft defect_drafts%ROWTYPE;
    v_new_status TEXT;
BEGIN
    IF p_action NOT IN ('approve', 'reject') THEN
        RAISE EXCEPTION 'Action must be approve or reject' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(trim(p_reviewer), '') = '' THEN
        RAISE EXCEPTION 'Reviewer is required' USING ERRCODE = '22023';
    END IF;

    v_new_status := CASE p_action WHEN 'approve' THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE defect_drafts
       SET status = v_new_status,
           reviewer = trim(p_reviewer),
           review_note = NULLIF(trim(p_note), ''),
           reviewed_at = now(),
           updated_at = now()
     WHERE defect_id = p_defect_id
       AND status = 'PENDING_APPROVAL'
    RETURNING * INTO v_draft;

    IF NOT FOUND THEN
        IF NOT EXISTS (SELECT 1 FROM defect_drafts WHERE defect_id = p_defect_id) THEN
            RAISE EXCEPTION 'Defect draft not found' USING ERRCODE = 'P0002';
        END IF;
        RAISE EXCEPTION 'Defect draft has already been reviewed; decision cannot be changed'
            USING ERRCODE = '40001';
    END IF;

    INSERT INTO defect_audit_events (defect_id, event_type, actor, details)
    VALUES (v_draft.defect_id,
            CASE p_action WHEN 'approve' THEN 'APPROVED' ELSE 'REJECTED' END,
            trim(p_reviewer),
            jsonb_build_object('note', NULLIF(trim(p_note), ''), 'status', v_new_status));

    RETURN jsonb_build_object('outcome', lower(v_new_status), 'defect', to_jsonb(v_draft));
END;
$$;

-- Guard for a future Jira adapter. This records submission intent only; it
-- does not make a Jira API call or transition the draft to SUBMITTED.
CREATE OR REPLACE FUNCTION request_defect_submission(
    p_defect_id UUID,
    p_actor TEXT DEFAULT 'n8n'
) RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft defect_drafts%ROWTYPE;
BEGIN
    SELECT * INTO v_draft
      FROM defect_drafts
     WHERE defect_id = p_defect_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Defect draft not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_draft.status <> 'APPROVED' THEN
        RAISE EXCEPTION 'Only APPROVED drafts may be submitted' USING ERRCODE = '42501';
    END IF;

    INSERT INTO defect_audit_events (defect_id, event_type, actor, details)
    VALUES (v_draft.defect_id, 'SUBMISSION_REQUESTED',
            COALESCE(NULLIF(trim(p_actor), ''), 'n8n'),
            jsonb_build_object('status_at_request', v_draft.status));

    RETURN jsonb_build_object('outcome', 'approved_for_submission', 'defect', to_jsonb(v_draft));
END;
$$;
