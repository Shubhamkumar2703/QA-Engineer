# 002 - Native n8n nodes over custom MCP services

## Status
Accepted

## Context
The original architecture proposal called for a custom MCP server per
external system (Swagger, Excel, Jira). Building protocol-compliant MCP
servers for each is real engineering effort with no benefit until
something other than this project's own agents needs to call the same
tools.

## Decision
Use n8n's native HTTP Request, Spreadsheet File, and Jira nodes directly
as the tool layer for Milestone 1. No custom MCP servers yet.

## Consequences
Much less code to write and maintain for v1. If a future milestone needs
a tool n8n doesn't natively support well, or genuinely needs
protocol-level MCP compliance (e.g. to share tools with another client),
build a custom MCP server for that specific case at that point.
