# 004 - Decision Agent must return structured JSON, never prose

## Status
Accepted

## Context
Downstream agents (Documentation, Jira) need to act on the Decision
Agent's verdict programmatically. Free-form prose output would require
re-parsing/re-interpreting the verdict at every consumer.

## Decision
The Decision Agent always returns:
{status, confidence, reasoning, evidence, next_action}
Documentation and Jira agents read this object directly.

## Consequences
More reliable downstream behavior, easier to log and measure. Requires
prompt discipline to keep the model from drifting into prose — worth
testing against a handful of known cases before trusting it in the
pipeline.
