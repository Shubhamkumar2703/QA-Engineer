# Workflow Standards

## Status
Accepted (introduced in Task 2.5)

## Purpose

Task 2 (Excel Ingestion) proved the pattern. This document writes that
pattern down so API Agent, Decision Agent, Documentation Agent, Jira
Agent, and anything after them, look like they were built by the same
engineer (`DEVELOPMENT_PLAYBOOK.md`, "Purpose"). It complements, and does
not replace, `docs/architecture/repository-design.md` section 2 (file and
folder naming) - this document covers conventions *inside* a workflow:
node naming, error handling, validation, and how workflows talk to each
other.

If anything here conflicts with `docs/architecture/milestone-1.md` or an
ADR, the milestone doc / ADR wins (`CLAUDE.md`, "Source of Truth").

---

## Workflow naming

Unchanged from `docs/architecture/repository-design.md`: `NN-purpose.json`
in `n8n/workflows/`, numbered in execution order.

| File | Workflow `name` field |
|---|---|
| `01-ingestion.json` | `01 - Excel Ingestion` |
| `02-api-agent.json` | `02 - API Agent` |
| `03-decision-agent.json` | `03 - Decision Agent` |
| `04-documentation-agent.json` | `04 - Documentation Agent` |
| `05-jira-agent.json` | `05 - Jira Agent` |

The workflow's internal `name` field always matches its file, prefixed
with the same two-digit number, so the n8n UI list and the repo listing
read the same way.

## Node naming

- Title Case, human-readable, describes what the node *does*, not the
  node type: `Filter Empty Rows`, not `Filter1` or `IF Node`.
- A node that maps one canonical concept from this project's vocabulary
  (Planner, API Agent, Decision Agent, ...) is named exactly that
  concept, with no decoration: `Planner`, not `Planner Node` or
  `Call Planner`.
- A Code node's name says what it computes, not that it's a Code node:
  `Normalize To Test Case JSON`, not `Code` or `JS Transform`.
- Sticky notes are named for what they annotate (`Scope Note`,
  `Contract Note`), so they're identifiable in the node list without
  opening them.

## Node responsibility ("one job per node")

Each node does exactly one of: fetch, parse, map/rename fields, filter,
validate, transform/build, or route. If a Code node's comment needs "and"
to describe what it does, it's probably two nodes. `01-ingestion.json`'s
chain is the reference example:

```
Parse Excel Rows            -> parses the file
Map Excel Columns & ...     -> maps raw headers to canonical fields, tags metadata
Filter Empty Rows           -> filters
Flag Duplicate Test IDs     -> validates (batch-level)
Normalize To Test Case JSON -> validates (row-level) + builds the domain object
Build Planner Routing ...   -> routes
```

## Column / field mapping

No workflow may reference a raw external header/column name
(`row['Test ID']`) outside of a single `COLUMN_MAP`-style object, defined
once, at the top of the one node responsible for translating that external
shape into this project's canonical field names. Every other node in the
workflow only ever sees canonical snake_case field names. This is what
lets a template change be a one-line edit instead of a search-and-replace
across the workflow (see `Map Excel Columns & Tag Metadata` in
`01-ingestion.json`).

## Validation

- Validate as early as the data allows, but no earlier than the point
  where canonical field names exist (i.e. after column mapping).
- Row-level checks (missing field, unsupported enum value) belong in a
  node that runs once per item. Checks that require seeing every row at
  once (duplicate detection) belong in a dedicated node running once for
  the whole batch - do not try to do both in one node.
- A failed validation produces the shared error object
  (`docs/contracts/error-payload.md`), it never throws and kills the rest
  of the batch, and it never gets silently dropped. This is the concrete
  form of Milestone 1's "fail loudly instead of silently" rule.
- Keep the list of "what's currently valid" (e.g.
  `SUPPORTED_VERIFICATION_TYPES`) and the list of "where valid values get
  routed" (e.g. `AGENT_ROUTES`) as close together as n8n allows, and keep
  them in sync by hand - n8n Code nodes cannot share JS constants across
  nodes, so this is a manual-sync convention, not an enforced one. Note
  the coupling in a comment at both definitions.

## Error handling

Use the shared error object exactly as specified in
`docs/contracts/error-payload.md`. Every new `code` a workflow introduces
gets added to that document's error-code table in the same change that
introduces it.

## Success outputs / JSON communication

- Workflows never pass free-form prose between each other. Every
  hand-off is a documented JSON shape living in `docs/contracts/`.
- A workflow that hands data to another workflow uses the routing
  contract shape from `docs/contracts/planner-contract.md` (envelope +
  domain object), not a bare domain object - this is what lets a
  receiving workflow tell a valid item apart from an error without
  guessing.
- Nothing downstream re-derives a value another workflow already computed
  (e.g. Decision Agent's verdict is read directly, never re-inferred from
  prose - ADR 004). The same rule applies to every future hand-off point.

## Versioning

- Each workflow's `workflow_version` (as emitted in its outputs) tracks
  that workflow's own contract-shape version, independent of the other
  workflows - see the Versioning rules section of
  `docs/contracts/planner-contract.md`.
- A workflow's exported JSON is committed on every change, per
  `docs/architecture/repository-design.md` section 5 - there is no
  separate "workflow file version" beyond git history plus the
  `workflow_version` string emitted in its output.

## Folder conventions

Unchanged from `docs/architecture/repository-design.md` section 1.
`docs/contracts/` (new in Task 2.5) holds one file per shared payload
shape exchanged between workflows - `planner-contract.md`,
`error-payload.md`, and one new file per future contract (e.g. a future
`decision-contract.md` would formalize what ADR 004 already specifies).

## Testing expectation

Every workflow ships with regression fixtures under
`test-scripts/samples/` covering at minimum: one fully valid case, one
case with the workflow's specific "ignore this" condition (e.g. blank
row), and one case per validation error the workflow can produce. See
`test-scripts/samples/valid.xlsx`, `blank-row.xlsx`, `missing-column.xlsx`,
`duplicate-test-id.xlsx`, and `invalid-verification-type.xlsx` for the
ingestion workflow's set.
