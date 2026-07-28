# 001 - Use n8n as the orchestrator

## Status
Accepted

## Context
We need something to coordinate the ingestion → agent → report/ticket
pipeline. Options considered: a custom FastAPI backend, or n8n as a
visual workflow orchestrator.

## Decision
Use n8n. It already provides HTTP Request, Postgres, Spreadsheet File,
and Jira nodes, which covers everything Milestone 1 needs without
custom service code.

## Consequences
Faster to build for v1. Workflow logic lives in exported JSON rather
than Python, which is less flexible for complex branching but adequate
for the current scope. Revisit if/when the orchestration logic outgrows
what n8n's nodes and Code nodes can express cleanly.
