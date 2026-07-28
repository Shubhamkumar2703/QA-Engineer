# Repository Design
## n8n-based test automation project — foundation for Milestone 1 onward

This is scoped to the plan we locked in: n8n as the orchestrator, no custom
FastAPI backend, no protocol-compliant MCP servers yet. Where n8n has a
native node that does the job (HTTP Request, Google Sheets/Excel, Jira),
we use it directly rather than building a wrapper service around it. If a
custom MCP server becomes genuinely necessary later (Milestone 2+), it gets
its own folder at that point — the layout below leaves room for it without
forcing it now.

---

## 1. Folder layout

```
qa-test-agent/
│
├── n8n/
│   ├── workflows/              # exported workflow JSON, one file per workflow
│   │   ├── 01-ingestion.json
│   │   ├── 02-api-agent.json
│   │   ├── 03-decision-agent.json
│   │   ├── 04-documentation-agent.json
│   │   └── 05-jira-agent.json
│   └── credentials.example.json  # placeholder shape only, never real secrets
│
├── prompts/
│   ├── decision-agent/
│   │   ├── v1.md
│   │   └── v2.md                # old versions kept, never overwritten
│   └── README.md                # explains the versioning convention
│
├── test-scripts/
│   └── samples/                 # public/sample test cases only — see Section 6
│
├── reports/
│   └── .gitkeep                 # generated Excel reports land here, gitignored
│
├── db/
│   └── init/
│       └── 001_init_schema.sql  # creates the runs/decisions logging tables
│
├── docs/
│   └── architecture/
│       ├── milestone-1.md
│       ├── repository-design.md   # this file
│       └── decisions/              # Architecture Decision Records — see Section 7
│           ├── 001-use-n8n.md
│           ├── 002-native-nodes-over-custom-services.md
│           ├── 003-postgres-for-logging.md
│           └── 004-json-only-decision-contract.md
│
├── docker/
│   └── postgres/
│       └── Dockerfile           # only if you need custom extensions; otherwise delete and use the base image directly
│
├── docker-compose.yml
├── .env.example
├── .gitignore
└── README.md
```

**Why this shape:**
- `n8n/workflows/` holds *exported* JSON, not your live n8n instance state — see Section 5 for why this matters.
- `prompts/` is separated from workflows because prompts change on their own cadence and need their own version history (this is what `prompt_version` in your data schema points at).
- `test-scripts/samples/` is deliberately the only test-data folder that's committed — real internship scripts never enter this repo (Section 6).
- `db/init/` is plain SQL, not an ORM/migration framework — you don't need Alembic for two tables. Add one when the schema outgrows a single file.
- No `mcp-servers/` folder yet. When Milestone 2 genuinely needs one, create it then — an empty placeholder folder just invites premature building.

---

## 2. Naming conventions

| What | Convention | Example |
|---|---|---|
| Workflow export files | `NN-purpose.json`, numbered in execution order | `03-decision-agent.json` |
| Prompt files | `vN.md` inside a folder named after the agent | `prompts/decision-agent/v2.md` |
| Docker Compose services | lowercase, hyphenated, matches folder where relevant | `n8n`, `postgres` |
| Environment variables | `SCREAMING_SNAKE_CASE`, prefixed by the service that owns them | `JIRA_API_TOKEN`, `SWAGGER_BASE_URL`, `N8N_BASIC_AUTH_PASSWORD` |
| Database tables | lowercase, plural, snake_case | `runs`, `decisions`, `jira_tickets` |
| Git branches | `feature/short-description`, `fix/short-description` | `feature/duplicate-ticket-check` |

The rule underneath all of these: **the name should tell you where to find the thing without opening it.** If you're ever unsure what to call something, that's usually a sign it's doing two jobs and should be split.

---

## 3. Docker Compose structure

```yaml
services:
  n8n:
    image: n8nio/n8n:latest
    ports:
      - "5678:5678"
    environment:
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./reports:/data/reports
      - ./test-scripts:/data/test-scripts
    depends_on:
      - postgres

  postgres:
    image: postgres:16
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./db/init:/docker-entrypoint-initdb.d

volumes:
  n8n_data:
  pg_data:
```

Two services, on purpose. Everything else from the earlier "final tech
stack" proposal (Redis, Qdrant, a dedicated Playwright service) gets added
as its own service block exactly when a milestone needs it — not before.
Adding an unused service to Compose costs you nothing to write and
something real to maintain (image pulls, port conflicts, "why is this
container running" six months from now).

---

## 4. Environment variables

`.env.example` — committed, no real values:

```
# n8n
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=changeme

# Postgres
POSTGRES_DB=qa_agent
POSTGRES_USER=qa_agent
POSTGRES_PASSWORD=changeme

# AI
ANTHROPIC_API_KEY=

# Swagger / target API under test
SWAGGER_BASE_URL=
SWAGGER_SPEC_URL=

# Jira
JIRA_BASE_URL=
JIRA_EMAIL=
JIRA_API_TOKEN=
JIRA_PROJECT_KEY=
```

`.env` (real values) is gitignored, never committed. Every variable in
`.env.example` should exist in real `.env` too — if you add a new variable
while building, add it to `.env.example` in the same commit, with a blank
or placeholder value. That file is the single source of truth for "what
does this project need to run," so it goes stale fast if you don't treat
it as part of the change, not an afterthought.

---

## 5. Development workflow

**n8n workflows as version-controlled files.** n8n's live state lives in its
own database inside the container — that's not something you can diff or
review in a PR. The workflow: build/edit in the n8n UI locally, then export
the workflow to JSON (n8n has a built-in export) and commit that file to
`n8n/workflows/`. Re-import on another machine (or after a fresh
`docker compose up`) via the same UI import. It's a manual step, but it's
what makes your workflows reviewable and diffable like any other code.

**Branching.** `main` stays runnable at all times — every commit on `main`
should be a state where `docker compose up` + workflow import gives you a
working (if incomplete) system. Build each task from the Milestone 1 doc on
its own `feature/` branch, merge when it works end-to-end for at least one
real test case.

**Prompt changes are commits, not edits.** When you change the Decision
Agent's prompt, save it as a new version file (`v3.md`) rather than
overwriting `v2.md`. This is what lets `prompt_version` in your logging
schema mean something later — "this run used prompt v2" only works if v2
still exists to look at.

**Local dev loop:**
1. `docker compose up -d`
2. Open n8n UI at `localhost:5678`, import the latest workflow JSON if starting fresh
3. Drop a test script into `test-scripts/samples/`
4. Trigger the workflow, watch it run
5. Check `reports/` for the Excel output and Postgres (`runs`/`decisions` tables) for the logged trace
6. Export the workflow again if you changed anything, commit

**Before merging a feature branch:** run it against at least one known-PASS
and one known-FAIL sample test case and confirm the Excel row and (for the
FAIL case) the Jira draft both look right. This is your whole test
strategy for v1 — it doesn't need to be more formal than that yet.

---

## 6. What never gets committed

- Real internship test scripts or any file that references the actual
  Infosys codebase, endpoints, or data — `test-scripts/` only ever holds
  samples from a public repo you're using to build against
- `.env` (real secrets)
- `n8n/credentials.example.json` shows the *shape* n8n credentials take,
  never real tokens — actual credentials are entered through the n8n UI
  and stored in its own encrypted store, not in a file
- Generated reports in `reports/` (gitignored — they're output, not source)
- Anything under `docker/postgres` if you end up not needing a custom
  Postgres image — delete rather than leave an empty placeholder

`.gitignore` starting point:
```
.env
reports/*
!reports/.gitkeep
n8n_data/
pg_data/
__pycache__/
```

---

## 7. Architecture Decision Records

`docs/decisions/` holds one short file per significant technical choice —
not every choice, just the ones you'd otherwise have to re-litigate or
explain from memory six months from now. Format:

```markdown
# 001 - Use n8n as the orchestrator

## Status
Accepted

## Context
[what problem were we solving, what were the options]

## Decision
[what we chose]

## Consequences
[what this makes easier, what it makes harder or defers]
```

Number sequentially, never renumber or delete old ones — if a decision gets
reversed later, add a new ADR that supersedes it and says so, rather than
editing the old one. The value is in the trail, not just the current state.
Four are already written from decisions we've made in this planning
session: `001-use-n8n.md`, `002-native-nodes-over-custom-services.md`,
`003-postgres-for-logging.md`, `004-json-only-decision-contract.md`.
