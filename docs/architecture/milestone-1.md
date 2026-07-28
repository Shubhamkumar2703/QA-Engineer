# Milestone 1 — System Design Document
## AI-Driven Test Automation Platform

---

## 1. Problem statement

Testing today is manual and fragmented: a test script is read by a human, who
manually checks the codebase, calls APIs via Swagger, inspects the database,
and — if something's wrong — manually writes up an Excel report and files a
Jira ticket. This project replaces that manual loop with a system of
specialized AI agents, each responsible for one part of the investigation,
coordinated by a planner and a decision-maker, producing the same two
artifacts a human QA engineer would: an updated test report and, where
needed, a Jira bug ticket.

**Scope of Milestone 1**: prove the full pipeline end-to-end on the
*narrowest slice that's still real* — API-level test cases only. No
Repository, Database, or UI agents yet. No dashboard. The goal is one test
case going in and a correct Excel row + correct Jira ticket (when warranted)
coming out, fully automated, with a human approval checkpoint before
anything is filed.

---

## 2. Goals and non-goals

**Goals (v1)**
- Ingest a test case (from the existing test script format)
- Execute the relevant API call(s) via the Swagger MCP
- Have a Decision Agent judge pass/fail against expected result
- Write the result to Excel via the Excel MCP
- On FAIL, draft a Jira ticket and hold it for human approval before creation
- Log every agent decision and every human override, for accuracy tracking

**Non-goals (deferred to later milestones)**
- Repository Agent / code-level verification (Milestone 2)
- Database Agent / data verification (Milestone 2)
- UI Agent / Playwright browser testing (Milestone 3)
- Dashboard (Milestone 4)
- Multi-model routing (Claude + GPT + Ollama) — pick one model for v1
- Auto-approval of Jira tickets — stays human-gated until accuracy is measured

---

## 3. High-level architecture

```
Test Script (Excel)
       │
       ▼
  n8n Ingestion Workflow  ──► normalizes rows to Test Case JSON
       │
       ▼
  Planner Agent  ──► reads Test Case JSON, decides which agents are needed
       │
       ▼
  API Agent  ──► calls Swagger MCP, returns raw result
       │
       ▼
  Decision Agent  ──► compares expected vs actual, outputs verdict + reasoning
       │
       ├── PASS/BLOCKED/NOT RUN ──► Documentation Agent ──► Excel MCP
       │
       └── FAIL ──► Documentation Agent ──► Excel MCP
                  └──► Jira Agent (drafts ticket) ──► Human approval queue ──► Jira MCP
```

For Milestone 1, the Planner's job is trivial (there's only one path: API
Agent), but it's included from the start so the architecture doesn't need
reshaping when Repository/DB/UI agents are added in later milestones.

---

## 4. MCP server contracts (v1 scope)

### Swagger MCP
| | |
|---|---|
| Purpose | Execute API calls defined in the project's OpenAPI/Swagger spec |
| Exposed functions | `call_endpoint(method, path, params, body, auth)` → status code, response body, latency |
| Inputs | Endpoint identifier, request payload, auth token/context |
| Outputs | HTTP status, response JSON, response time |
| Failure modes | Endpoint unreachable, auth failure, timeout — all must be returned as structured errors, not exceptions that kill the run |

### Excel MCP
| | |
|---|---|
| Purpose | Read the incoming test script, write results back to the report |
| Exposed functions | `read_rows(file_path)`, `write_row(file_path, test_id, fields)`, `append_row(...)` |
| Inputs | File path, row data matching the fixed schema (Test ID, Description, Status, Tester, Date, Notes, Actual Result) |
| Outputs | Confirmation + updated file |
| Failure modes | File locked/open elsewhere, schema mismatch — surface clearly rather than silently skipping |

### Jira MCP
| | |
|---|---|
| Purpose | Draft and create bug tickets |
| Exposed functions | `draft_ticket(summary, description, expected, actual, labels, priority)` → draft object (not yet created), `create_ticket(draft_id)` → live Jira issue |
| Inputs | Ticket fields, project key, labels (e.g. `ai-detected`) |
| Outputs | Draft for review; Jira issue key once approved |
| Note | `draft_ticket` and `create_ticket` are deliberately separate calls — this is what enforces the human approval gate at the architecture level, not just in the workflow logic |

---

## 5. Agent responsibilities (v1 scope)

| Agent | Reads | Does | Never does |
|---|---|---|---|
| **Planner** | Test Case JSON | Decides which downstream agents are needed (v1: always API Agent) | Doesn't test anything itself |
| **API Agent** | Endpoint + params from test case | Calls Swagger MCP, returns raw result | Doesn't judge pass/fail |
| **Decision Agent** | API Agent's raw result + expected result from test case | Compares expected vs actual, outputs `{status, reasoning}` | Doesn't call any MCP directly |
| **Documentation Agent** | Decision Agent's verdict | Writes the Excel row via Excel MCP | Doesn't decide pass/fail, doesn't touch Jira |
| **Jira Agent** | Decision Agent's verdict (FAIL only) | Checks Jira for an existing open ticket tagged with this `test_id`; if found, adds a comment instead of drafting a new one. Otherwise drafts a new ticket via Jira MCP, waits for human approval, then creates | Never auto-creates without an approval signal; never creates a duplicate for a test_id that already has an open ticket |

### Decision Agent — output contract

Every Decision Agent call must return this exact shape, not free-form prose:

```json
{
  "status": "FAIL",
  "confidence": 0.98,
  "reasoning": "Password length validation not enforced; expected 422, API returned 200 with account created",
  "evidence": [
    "Expected: 422 Unprocessable Entity",
    "Actual: 200 OK, account created"
  ],
  "next_action": "create_jira"
}
```

`status` is one of `PASS | FAIL | BLOCKED | NOT_RUN`. `next_action` is one of
`write_report | create_jira | update_jira | none`. Downstream agents (Documentation,
Jira) read this object directly — they never re-derive a verdict from prose.

---

## 6. Example flow (traced end-to-end)

```
Test case: AUTH-021 "Verify password length validation"
Expected: API returns 422 for a password under 8 characters

Planner        → "This is an API-only test. Route to API Agent."
API Agent      → Calls POST /signup with a 5-char password
               → Swagger MCP returns: 200 OK
Decision Agent → Returns:
               { "status": "FAIL", "confidence": 0.98,
                 "reasoning": "Password length validation not enforced;
                   expected 422, API returned 200 with account created",
                 "evidence": ["Expected: 422", "Actual: 200"],
                 "next_action": "create_jira" }
Documentation Agent → Writes Excel row:
               Test ID: AUTH-021 | Status: FAIL | Tester: AI-Agent |
               Date: <today> | Notes: <Decision Agent's reasoning>
Jira Agent     → Checks for an existing open ticket tagged AUTH-021 → none found
               → Drafts ticket:
               Summary: "Password length validation missing on signup"
               Expected: 422 Unprocessable Entity
               Actual: 200 OK, account created
               Labels: ai-detected, needs-triage
               → Holds in approval queue
Human          → Reviews draft, approves
Jira Agent     → Creates live ticket JIRA-102, logs agent_verdict=FAIL, human_verdict=FAIL (agreement)

--- One week later, AUTH-021 fails again ---
Jira Agent     → Checks for an existing open ticket tagged AUTH-021 → finds JIRA-102 (still open)
               → Adds comment to JIRA-102 instead of creating a duplicate
```

---

## 7. Data schema (shared contract across all stages)

```json
{
  "test_id": "AUTH-021",
  "description": "Verify password length validation",
  "steps": "POST /signup with a 5-character password",
  "expected_result": "422 Unprocessable Entity",
  "actual_result": null,
  "status": null,
  "confidence": null,
  "evidence": null,
  "next_action": null,
  "verification_type": "api",
  "tester": "AI-Agent",
  "date": null,
  "notes": null,
  "agent_reasoning": null,
  "jira_key": null,
  "run_id": null,
  "workflow_version": null,
  "prompt_version": null,
  "model_version": null,
  "repo_commit": null,
  "timestamp": null,
  "human_verdict": null
}
```

This object is created at ingestion and progressively filled in by each
agent — nothing downstream invents new fields, they only populate what's
already defined. This keeps the Excel writer and Jira drafter simple: they
just map fields, they don't need to know how the value was derived.

The last seven fields (`run_id` through `human_verdict`) exist purely for
traceability and accuracy tracking — they don't drive any logic. `run_id`
ties every test case in a single execution together; `workflow_version`,
`prompt_version`, and `model_version` let you reconstruct exactly which
version of the system produced a given verdict months later; `human_verdict`
is filled in whenever a human approves or rejects a Jira draft, and is what
you'll eventually compare against `status` to measure agent accuracy.

---

## 8. Failure handling

| Failure | Handling |
|---|---|
| Swagger MCP unreachable / endpoint error | API Agent returns a structured error; Decision Agent sets status = `BLOCKED`, reasoning = the error, no Jira ticket drafted |
| Decision Agent can't determine a clear verdict | Status = `BLOCKED` with reasoning explaining the ambiguity — never force a PASS/FAIL guess |
| Excel MCP write fails (file locked, etc.) | Retry once, then fail the run loudly (n8n error output / notification) rather than silently dropping the result |
| Jira draft rejected by human | Logged as `human_verdict=REJECTED`, ticket not created, reasoning captured for later agent-accuracy analysis |
| n8n workflow crashes mid-run | Each test case is processed independently (Split In Batches), so one failure doesn't take down the whole batch |

---

## 9. Milestone 1 definition of done

- [ ] A single test case flows from Excel ingestion → API Agent → Decision Agent → Documentation Agent, producing a correct Excel row
- [ ] A FAIL case produces a correctly-drafted Jira ticket held in an approval queue
- [ ] Human approval creates the live Jira ticket; rejection logs the disagreement
- [ ] A repeat failure of a test_id with an already-open ticket adds a comment instead of creating a duplicate
- [ ] Decision Agent always returns the structured JSON contract (status/confidence/reasoning/evidence/next_action), never free-form prose
- [ ] Every verdict (agent + human) is logged with run_id, workflow_version, prompt_version, model_version, repo_commit, and timestamp, somewhere queryable (even a simple CSV/sheet) for future accuracy tracking
- [ ] Works against a sample public repo/API, not real internship data

## 10. Next milestones (not started yet)

- **Milestone 2**: Repository Agent (code-level checks) + Database Agent, Planner starts routing to multiple agents per test case
- **Milestone 3**: UI Agent via Playwright for the tests that need real visual verification
- **Milestone 4**: Dashboard for reviewing runs, approving tickets, and viewing agent accuracy over time

---

## 11. One-week build plan

This assumes you hold the scope exactly as defined above — no Kernel, no
Tool Manager abstraction, no Repository/DB/UI agents. Each day produces
something that runs, even if rough.

| Day | Build | Done when |
|---|---|---|
| 1 | Pick a sample public repo/API with Swagger docs. Set up n8n ingestion: file trigger → Spreadsheet File node → Code node normalizing rows to the Test Case JSON schema | A test script upload produces correct JSON for every row |
| 2 | Wire the Swagger MCP and API Agent to call one real endpoint | API Agent returns a real HTTP response for one hardcoded test case |
| 3 | Build the Decision Agent prompt enforcing the JSON output contract; test against 3-4 known pass/fail cases | Decision Agent's `status` matches your own manual judgment on all test cases |
| 4 | Wire the Excel MCP and Documentation Agent | A full run writes a correct row into the report file |
| 5 | Wire the Jira MCP, Jira Agent draft step, and the duplicate-ticket check (fake/sandbox Jira project is fine) | A FAIL produces a correct draft; a repeat FAIL adds a comment instead of a new ticket |
| 6 | Add the human approval gate (a Slack message or even a manual "approve" step in n8n is enough for v1) and the versioning/run_id logging | End-to-end: script in → Excel out → approved ticket created, fully logged |
| 7 | Run it against the real test script (5-10 cases), fix whatever breaks, write up what you learned | The system runs unattended on a real batch and you can explain every decision it made |

A week is realistic **for this scope specifically** — it's tight if you're
also working your internship hours, so treat Day 7 as float/buffer more
than a fixed deadline. It stops being realistic the moment any Kernel/Tool
Manager/Memory Manager pieces creep back in — those alone are easily a week
on their own.
