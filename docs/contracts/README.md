# Contracts

## Purpose

Every hand-off between workflows in this project is a documented JSON
shape, not free-form data one workflow happens to produce and another
happens to read. This folder is where those shapes live. The rule (from
`docs/workflow-standards.md`): a workflow never passes data to another
workflow without a corresponding file here describing exactly what's in
it, who produces it, who's allowed to consume it, and how it can change
over time without breaking a consumer that hasn't been updated yet.

Read this file first to find the contract you need, then open the
specific document for the full field-by-field spec.

---

## Current contracts

### Planner Contract

File: [`planner-contract.md`](./planner-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/01-ingestion.json` |
| Consumer | `n8n/workflows/02-api-request-builder.json` (for `agent: "api"` routes); future Repository/Database/UI agent workflows for their own `agent` values |
| Current version | `workflow_version: "1.0"` |
| Purpose | Normalizes an Excel test-script row into the shared Test Case JSON schema and wraps it in a routing envelope (`agent`, `next_node`) so the receiving agent knows what it's looking at without inspecting the data. |
| Backward compatibility | Additive-only for `"1.0"` - new optional fields don't require a version bump; consumers must ignore fields they don't recognize. A required-field change or renamed field bumps `workflow_version`. Adding a new agent route is a value-level change (new `AGENT_ROUTES` entry), not a shape-level one, so it does not require a version bump. |

### API Request Contract

File: [`api-request-contract.md`](./api-request-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/02-api-request-builder.json` |
| Consumer | The future HTTP Executor workflow (Task 3.2, not yet built) |
| Current version | `workflow_version: "1.0"`, `contract_version: "1.0"` |
| Purpose | Describes a fully-prepared HTTP request (method, URL, headers, query, body, auth strategy, timeout, expected result) derived from a Planner Contract's `test_case` - without sending it. Separates request *preparation* from request *execution*. |
| Backward compatibility | Same additive-only rule as the Planner Contract, tracked via two separate version fields: `workflow_version` for the producing workflow's internal changes, `contract_version` for the payload shape itself. Never embeds a real credential, so credential rotation or a new auth provider never requires a contract change - see `authentication` in that document. |

### HTTP Response Contract

File: [`http-response-contract.md`](./http-response-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/03-http-executor.json` |
| Consumer | `n8n/workflows/04-response-normalizer.json` |
| Current version | `workflow_version: "1.1"`, `contract_version: "1.0"` |
| Purpose | Describes what actually happened when an API Request Contract was executed - status code, headers, body, latency, timestamps - without judging PASS/FAIL. Separates request *execution* (Task 3.2, this document) from *normalization* (Task 3.3) and *judgment* (Decision Agent). |
| Backward compatibility | Same additive-only rule, tracked via `workflow_version` / `contract_version`. Carries `expected` and `test_case` forward unchanged from the API Request Contract so the Decision Agent doesn't need to join across contracts. `workflow_version` bumped to `1.1` in Task 3.3 (contract shape unchanged) - every error payload this workflow produces now also carries `test_case`/`expected` in `details`. |

### Normalized Response Contract

File: [`normalized-response-contract.md`](./normalized-response-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/04-response-normalizer.json` |
| Consumer | The future Decision Agent workflow (Task 4, not yet built) |
| Current version | `workflow_version: "1.0"`, `contract_version: "1.0"` |
| Purpose | The single, stable shape every transport result - success or failure, 2xx through 5xx, timeout, connection refused, DNS failure - is normalized into before it reaches the Decision Agent. The Decision Agent never sees a raw HTTP Response Contract, never branches on which HTTP client executed the request, and never sees n8n/HTTP Request node internals. Still makes no PASS/FAIL judgment and calls no AI model - that stays the Decision Agent's job. |
| Backward compatibility | Same additive-only rule, tracked via `workflow_version` / `contract_version`. Carries `expected` and `test_case` forward unchanged, including for transport failures (timeout, connection refused, DNS failure) that never produced a real HTTP response. |

### Decision Contract

File: [`decision-contract.md`](./decision-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/05-decision-orchestrator.json` (Task 4.1) |
| Consumer | The future Documentation Agent (every verdict) and Jira Agent (`next_action: "create_jira"` only), Task 4.2+, not yet built |
| Current version | `workflow_version: "1.0"`, `contract_version: "1.0"` |
| Purpose | The `{status, confidence, reasoning, evidence, next_action}` verdict shape from ADR 004 / `milestone-1.md` section 5, updated per ADR 005 (`MANUAL_REVIEW` replaces `NOT_RUN`, `update_jira` dropped, `flag_for_review` added). The first contract in the pipeline whose producer may call an AI model - every contract before it is produced by an AI-free workflow. Full reasoning design: `docs/architecture/decision-agent-design.md`. |
| Backward compatibility | Same additive-only rule, tracked via `workflow_version` / `contract_version`. Carries `test_case` forward unchanged, same as every prior contract. Adds `decision_basis` (new) so a $0 deterministic verdict and a paid model call are distinguishable per instance, for both cost tracking and hallucination auditing. |

### Report Contract

File: [`report-contract.md`](./report-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/06-documentation-agent.json` (Task 5) |
| Consumer | Renderer workflows only - the Excel Writer (`n8n/workflows/06.1-excel-writer.json`, Task 5.1) and the Jira Agent (`n8n/workflows/07-jira-agent.json`, Task 6), and eventually PDF/Google Sheets/dashboard consumers. Each renderer reads the same Report Contract; none of them is this contract's producer. |
| Current version | `workflow_version: "1.0"`, `report_version: "1.0"` |
| Purpose | The canonical, output-format-independent QA report record - `{test_case, decision, report}` - built by formatting-only from a validated Decision Contract. No AI call, no re-judgment, no Excel/PDF/Sheets/dashboard/Jira-specific field anywhere in this shape; those are downstream renderers, not part of what this contract means. |
| Backward compatibility | Same additive-only rule, tracked via `workflow_version` / `report_version`. Carries `test_case` and the full `decision.verdict`/`decision.decision_basis` forward unchanged, same convention as every prior contract. |

### Jira Draft Contract

File: [`jira-draft-contract.md`](./jira-draft-contract.md)

| | |
|---|---|
| Producer | `n8n/workflows/07-jira-agent.json` (Task 6) |
| Consumer | Not yet built - a future duplicate-check integration, human approval queue, and Jira API submission workflow. This contract's producer stops at the draft; no Jira issue is ever created by it. |
| Current version | `workflow_version: "1.0"`, `jira_version: "1.0"` |
| Purpose | The canonical, not-yet-submitted representation of a Jira ticket for a `FAIL` (always) or `MANUAL_REVIEW` (configurable, off by default) test case - `{report, jira}`. No AI call, no direct Jira API call anywhere in this shape or its producer; `priority` reuses the Decision Contract's already-computed `next_action` rather than re-deriving a confidence threshold. |
| Backward compatibility | Same additive-only rule, tracked via `workflow_version` / `jira_version`. Carries the complete Report Contract forward unchanged under `report` (not a subset), same convention as every prior contract. |

### Error Payload

File: [`error-payload.md`](./error-payload.md)

| | |
|---|---|
| Producer | Any workflow - this is the one contract every workflow can produce, not just one specific workflow |
| Consumer | Whatever node/workflow receives the erroring workflow's output; ultimately a human reviewing a failed run |
| Current version | `workflow_version` field reflects whichever workflow produced a given instance of this object - there is no separate version for the error shape itself, since it's intentionally minimal and stable |
| Purpose | One shape for "this item failed validation" across every workflow, so a generic `item.status === 'ERROR'` check works everywhere instead of each workflow inventing its own failure shape. Implements Milestone 1's "fail loudly instead of silently" rule at the data level. |
| Backward compatibility | The object shape (`status`/`stage`/`code`/`message`/`details`/`timestamp`/`workflow_version`) is fixed and shared - it does not change per workflow. New `code` values are added freely (see each contract's error-code table) without any version bump, since `code` values are data, not shape. |

---

## Future contracts

Not built yet - listed here so the shape of what's coming is visible
without digging through milestone docs. Do not implement these until
their task begins (`CLAUDE.md`, "Out of Scope").

| Contract | Producer (planned) | Consumer (planned) | Formalizes |
|---|---|---|---|
| Excel Report Contract | Excel Writer (Task 5.1) | (terminal - writes a row to the Excel report via the Excel MCP/node) | What the Excel Writer needs from a Report Contract to write a correct report row, and what it confirms back (success/failure of the write). Renderer-specific; does not change what the Report Contract itself means. |
| Jira Submission Contract | Human approval queue / future Jira submission workflow | Jira MCP/node | The separate approval → `create_ticket` hand-off described in `docs/architecture/milestone-1.md` section 4, plus the duplicate-ticket check's real input/output, once the Jira Draft Contract's "Duplicate Check" / "Draft Ticket" / "Human Approval" / "Create / Update Jira" extension points (`docs/contracts/jira-draft-contract.md`) are actually implemented. |

**Note (Task 5):** the "Documentation Contract" this table previously
anticipated has been superseded by the Report Contract above, built as
Task 5 itself rather than left for a later task - see that document's
Purpose section for why it's deliberately renderer-independent (Excel is
one of several future consumers, not the producer's only concern).

**Note (Task 6):** the "Jira Contract" this table previously anticipated
has been superseded by the Jira Draft Contract above, built as Task 6
itself. What remains future work is only the part after the draft -
duplicate-check, approval, and submission - now tracked as the "Jira
Submission Contract" row.

When one of these is built, add it to "Current contracts" above using the
same table shape, and move its row out of this table.

---

## Conventions every contract document follows

Each file in this folder documents, at minimum: Purpose, Producer,
Consumer, Required fields, Optional fields, Example payload, Versioning
rules, and Future/compatibility notes. See `docs/workflow-standards.md`
for the full conventions every workflow (and by extension, every contract
it produces) must follow.
