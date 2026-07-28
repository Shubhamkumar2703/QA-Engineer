# 003 - Postgres for run/decision logging

## Status
Accepted

## Context
Every agent decision needs to be logged for traceability and for
measuring agent accuracy against human review. Options: flat files/CSV,
or a real database.

## Decision
Use Postgres, with two tables (`runs`, `decisions`) plus a small
`jira_tickets` table that backs the duplicate-ticket check.

## Consequences
Slightly more setup than a CSV, but makes the duplicate-ticket lookup
and any future accuracy queries trivial instead of requiring file
parsing. Cheap to run locally via the same Docker Compose as n8n.
