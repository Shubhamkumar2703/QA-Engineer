# Excel Renderer

## Status
Accepted (introduced in Task 5.1)

## Purpose

The first renderer built on top of the Documentation Agent's Report
Contract (`docs/contracts/report-contract.md`). It consumes a validated
Report Contract and updates exactly one row of an existing QA Excel
workbook - the renderer-owned columns only. It is a pure renderer: it
never inspects a Decision Contract directly, never calls an AI model,
never judges a verdict, and never modifies the Report Contract it reads.

This document also records the general renderer architecture pattern
this workflow establishes - every future renderer (Google Sheets, PDF,
dashboards) is expected to follow the same shape.

## Producer

`n8n/workflows/06.1-excel-writer.json` (Task 5.1).

## Consumer

None. This workflow is terminal for a given test case's renderer path -
it writes to the workbook and stops. A future human or CI step reads the
workbook file directly; nothing in this project's pipeline consumes this
workflow's output as an input contract.

---

## Renderer architecture pattern

Every renderer - this one and every future one - follows the same
four-stage shape, so the Report Contract never has to know or care which
renderer is reading it:

```
Report Contract
      |
      v
Renderer Adapter     <- Report Contract fields only, mapped to
      |                  renderer-agnostic canonical field names
      v
COLUMN_MAP           <- canonical field names -> this renderer's
      |                  real column/field identifiers
      v
Renderer             <- format-specific: locate the target row/
                         record, merge, persist
```

For Excel today:

```
Report Contract
      |
      v
Excel Adapter        <- 06.1-excel-writer.json's 'Excel Adapter' node
      |
      v
COLUMN_MAP            <- 'Apply Column Map' node
      |
      v
Workbook              <- 'Read Workbook File' onward
```

For a future Google Sheets renderer, only the last two stages would
differ - `COLUMN_MAP` would target Sheets column letters/ranges instead
of Excel headers, and `Renderer` would call the Sheets API instead of
reading/writing an xlsx file. `Sheets Adapter` would produce the exact
same canonical field object `Excel Adapter` does below, since both derive
from the same Report Contract fields and nothing about those fields is
Excel-specific. **The Report Contract itself never changes to support a
new renderer** - this is what keeps the Documentation Layer independent
of storage technology (per Task 5's original brief and this task's
"Renderer Adapter" refinement of it).

### Why this isn't three separate n8n sub-workflows

Each stage above is a dedicated node with exactly one job (per
`docs/workflow-standards.md`'s "one job per node" rule), not a separate
workflow file - the same reasoning `05-decision-orchestrator.json`'s
Decision Engine Note already gives for keeping tightly-coupled stages in
one file: this project has never yet exercised a real n8n cross-workflow
`Execute Workflow` call, and each stage's output is the next stage's only
input (no independent trigger of its own), so splitting them into
separate importable files would add untested mechanism without adding
real isolation. A future Sheets renderer is still a **separate workflow
file** from this one (`06.2-sheets-writer.json` or similar) - the
stage-per-node structure is about internal organization within one
renderer, not about reusing nodes across renderers.

---

## Node-by-node

| Node | Job |
|---|---|
| `Validate Contract` | Confirms the incoming item is a well-formed Report Contract; passes an upstream ERROR payload straight through unchanged. |
| `Route Validation Errors` | Standard ERROR-passthrough IF, same pattern as every prior workflow. |
| `Excel Adapter` | **Renderer Adapter stage.** The only node that reads `report.*` / `test_case.*` field names. Outputs `{ test_id, fields: {...9 canonical names...} }`. |
| `Apply Column Map` | **COLUMN_MAP stage.** The single source of truth for this renderer's real Excel column headers (`docs/workflow-standards.md`'s column-mapping rule). Outputs `{ __lookup_header, __lookup_value, __updates }`. |
| `Read Workbook File` | Reads the workbook file from disk. Error output -> `Build Workbook Read Error`. |
| `Parse Workbook Rows` | Parses the xlsx binary into one n8n item per row. |
| `Locate & Merge Row` | **Renderer stage, part 1.** Finds the row whose lookup column matches `__lookup_value`; overlays `__updates` onto that row only; every other row and every other column on the matched row is preserved unchanged by construction. |
| `Row Located?` | Branches on whether a match was found. |
| `Build Target Row Not Found Error` | No matching row - this workflow updates, it never appends. |
| `Expand Rows For Write` | Turns the merged row set back into one item per row for the write node. |
| `Write Workbook Rows` | **Renderer stage, part 2.** Renders every row (unchanged and updated) back into an xlsx binary. |
| `Write Workbook File` | Writes the binary to disk, in place. Error output -> `Build Workbook Write Error`. |
| `Build Write Confirmation` | A deterministic `{status: 'WRITTEN', test_id, file_path, columns_updated, written_at}` record for logging/auditing - not a new contract. |
| `Renderer Complete` | Terminal hand-off. Every path (success, validation error, row-not-found, read/write error) converges here. |

---

## Column mapping

`COLUMN_MAP` lives in exactly one place: the `Apply Column Map` node.

### Renderer-owned columns (written by this workflow)

| Canonical field | Excel column | Source (Report Contract) |
|---|---|---|
| `status` | `Status` | `report.status` |
| `actual_result` | `Actual Result` | `report.actual_result` |
| `notes` | `Notes` | `report.reasoning` |
| `tester_notes` | `Tester Notes` | `report.tester_notes` |
| `confidence` | `Confidence` | `report.confidence` |
| `decision_basis` | `Decision Basis` | `report.decision_basis` |
| `manual_review` | `Manual Review` | `report.manual_review` |
| `execution_date` | `Execution Date` | `report.execution_time` |
| `evidence_summary` | `Evidence Summary` | `report.evidence_summary` |

`notes` maps to `report.reasoning` (the verdict's explanation - the
original Excel MCP schema's "Notes" column per
`docs/architecture/milestone-1.md` sections 4 and 6), kept distinct from
`tester_notes` (`report.tester_notes` - the fixed per-status action
guidance).

### Preserved columns (never written by this workflow)

`Test ID` (the lookup key - read, never written), `Description`,
`Steps`, `Expected Result`. These are never referenced in `COLUMN_MAP`'s
`__updates` output at all, so there is no code path in this workflow that
can write to them - this is a structural guarantee, not a runtime check.
Any other column the workbook happens to have (beyond the ones listed
here) is also preserved automatically, since `Locate & Merge Row` spreads
the original row object before overlaying `__updates`.

### `Test ID` lookup

The row to update is located by exact string match of the workbook's
`Test ID` column against the Report Contract's `test_case.test_id`. If no
row matches, the workflow produces `TARGET_ROW_NOT_FOUND` rather than
appending a new row - Task 5.1's brief scopes this workflow to updating
an existing row only (the row is expected to already exist from Excel
ingestion, Task 2).

---

## Preconditions

- A workbook already exists at `/data/reports/qa-report.xlsx` (the path
  fixed in both `Read Workbook File` and `Write Workbook File`; mounted
  via `docker-compose.yml`'s `./reports:/data/reports` volume), with a
  header row containing at minimum every column listed above.
- Every row this workflow will ever be asked to update already exists in
  that workbook (typically seeded at the same time as ingestion, Task 2 -
  out of scope for this task to build that seeding step).

---

## Error codes (`stage: "excel_writer"`)

See `docs/contracts/error-payload.md`'s "Excel Writer workflow" section
for the canonical table (`INVALID_REPORT_CONTRACT`,
`REPORT_FILE_UNAVAILABLE`, `TARGET_ROW_NOT_FOUND`,
`WORKBOOK_WRITE_FAILED`) - added there in Task 6, closing the gap this
section originally flagged (Task 5.1's own deliverable list hadn't
included a contracts-doc update). No retry logic exists for any of
these - same "fail loudly, once, no classification" convention as every
prior workflow's error handling.

---

## Idempotency and row integrity

- **Read-modify-write, not append.** Every existing row is read, exactly
  one row is updated in memory, and the complete row set (all rows,
  unchanged ones included) is written back. This is what guarantees every
  other test's row - and every non-renderer-owned column on the target
  row - stays byte-for-byte identical across a run.
- **Idempotent by construction.** Re-running this workflow with the same
  Report Contract locates the same row and overlays the same nine values
  again; no new row is ever appended, and the workbook converges to (and
  stays at) the same state.
- **Fixed file path, no path-traversal surface.** `/data/reports/
  qa-report.xlsx` is a literal constant in both I/O nodes - never derived
  from item data - so a malformed or adversarial Report Contract cannot
  redirect the read or the write to a different file.

## Future extension notes

- A Google Sheets renderer, PDF renderer, or dashboard consumer each
  reads the same Report Contract and adds its own workflow file following
  the four-stage pattern above - none of them requires a change to
  `06-documentation-agent.json` or `docs/contracts/report-contract.md`.
- If a future renderer needs a Report Contract field this contract
  doesn't currently expose, the fix is a new field on the Report Contract
  itself (additive, per that document's versioning rules) - never a
  renderer-specific field bolted onto this document alone.
