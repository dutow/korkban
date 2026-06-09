# pgboard — Design

Date: 2026-06-09
Source spec: `SPEC.md`

## Purpose

Read-only Kanban-style board for our JIRA project, rendering specific epics as
columns and their direct children as postits. Read-only, single global view,
Google-authenticated, periodic background polling of JIRA. Inspired by
`pgboard-demo.html`.

## High-level architecture

Rails 8 monolith, SQLite (4 split DBs: primary, cache, queue, cable),
SolidQueue for the recurring JIRA poller. Import-map JS with Turbo + Stimulus.

Three planes:

1. **Ingest** — `JiraSyncJob` runs every 60s under SolidQueue. Calls
   `JiraSync`, which uses the `jira-ruby` gem to fetch epics and their direct
   children, upserts into SQLite. Cadence switches between fast (every tick)
   and slow (skips ticks) based on whether a user has been active recently.
2. **Read** — `BoardController#show` renders from SQLite only. Modal/hover
   detail pages also read from SQLite via Turbo Frames. No JIRA call is ever
   made in the HTTP request path.
3. **Push** — After each successful sync, the job broadcasts a Turbo Stream
   over ActionCable with `action="morph"`. Subscribed clients morph the DOM in
   place. Open modals and collapsed sections are preserved.

Auth: `omniauth-google-oauth2`, email/domain allow-list from
`config/pgboard.yml`. Cookie session. Access is binary: in the allow-list or
not. No per-user state.

The SQLite snapshot **is** the cache. There is no separate HTTP/fragment
cache layer. Freshness is governed by poll cadence.

## Components

### Models (`app/models/`)

- `Epic` — `jira_key`, `name`, `priority`, `jira_status`, `raw_fields` (json),
  `last_seen_in_query_at`, `removed_at`
- `Issue` — `jira_key`, `epic_id` (fk), `issue_type`, `summary`, `jira_status`,
  `assignee_username`, `priority`, `created_at_jira`, `status_changed_at_jira`,
  `raw_fields` (json), `last_seen_in_query_at`, `removed_at`
- `SyncRun` — `started_at`, `finished_at`, `ok` (bool), `error_message`,
  `fetched_count`
- `Presence` — single-row table holding `last_seen_at`
- `BoardSnapshot` — single-row, `version` int bumped on each successful sync.
  Used as a cache key for the rendered partial and to detect "did anything
  change."

### Services (`app/services/`)

- `JiraClient` — thin facade over `jira-ruby`. Just wires auth from `Config`
  and exposes the few query helpers `JiraSync` needs. Trusts `jira-ruby` for
  HTTP, retries, and `Retry-After` handling.
- `JiraSync` — orchestrates a single sync: load epic query → fetch epics →
  fetch children per epic → upsert → bump snapshot version → broadcast.
- `BoardPresenter` — pure. Takes DB rows + config and returns ordered columns,
  the postit list per column grouped by display status, staleness bucket per
  postit, new/done partitioning, and the list of warnings (unmapped statuses).
- `StalenessCalculator` — current time + thresholds → `:fresh | :somewhat |
  :really`. Knows the "ignore staleness for new issues" rule.
- `Config` — singleton loading `config/pgboard.yml` at boot, validated.
  Missing keys raise `Config::MissingKey`.

### Controllers (`app/controllers/`)

- `ApplicationController` — `before_action :require_login`, `before_action
  :touch_presence`.
- `SessionsController` — handles the omniauth callback. Checks email against
  `auth.allowed_domains` / `auth.allowed_emails`, signs in or rejects.
- `BoardController#show` — renders `app/views/board/show.html.erb` from DB.
- `IssuesController#show` — turbo-frame target for a single issue's modal.
  Reads from DB.

### Jobs (`app/jobs/`)

- `JiraSyncJob` — recurring SolidQueue job, every 60s. Checks cadence,
  short-circuits if idle and last successful sync is recent enough, else
  calls `JiraSync.run!`. Records a `SyncRun`. No SolidQueue-level retry: the
  next tick handles failure naturally.

### Views (`app/views/`)

- `board/show.html.erb` — outer layout with theme toggle, filter bar (Stimulus
  controller `filters`), warning tray, stale banner, board container with
  `<%= turbo_stream_from "board" %>`.
- `board/_column.html.erb` — one epic.
- `board/_postit.html.erb` — one issue.
- `board/_warning_banner.html.erb`, `board/_stale_banner.html.erb`.
- `issues/_modal.html.erb` — turbo-frame target for `IssuesController#show`.

### Stimulus controllers (`app/javascript/controllers/`)

- `filters_controller.js` — chip toggles, CSS class application on the board
  container, URL hash sync. Survives morph because filter state lives on the
  controller, not in the morphed HTML.
- `theme_controller.js` — light/dark toggle, persisted in `localStorage`.

### Channels

- `BoardChannel` — broadcasts `turbo_stream.morph` of the rendered board after
  successful sync.

### Config files

- `config/pgboard.yml` — single file, sections: `jira`, `auth`, `polling`,
  `board`. Loaded once at boot via `Config`. See full example below.
- `.env` (or env vars in prod) — secrets only: `JIRA_API_TOKEN`,
  `JIRA_BASE_URL`, `JIRA_EMAIL`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
  `SECRET_KEY_BASE`.

## Data flow

### Boot

1. Rails loads `config/pgboard.yml` into `Config`. Missing keys raise; server
   fails to start.
2. SolidQueue starts, registers `JiraSyncJob` as recurring (60s).
3. Server ready. Board renders from whatever is in SQLite (empty on cold
   start).

### Poll tick (every 60s)

1. `JiraSyncJob#perform` reads `Presence.last_seen_at` and last `SyncRun`.
2. Determines mode: `active` if `last_seen_at` is within
   `polling.active_window_minutes`, otherwise `idle`.
3. If `idle` and the last successful sync is within
   `polling.idle_interval_minutes`, return without calling JIRA.
4. Otherwise `JiraSync.run!`:
   - Fetch epics via `board.epic_query`. Upsert `Epic` rows, set
     `last_seen_in_query_at = now`.
   - Per epic, fetch direct children (`parent = EPIC-KEY`). Upsert `Issue`
     rows.
   - For each issue, if the `jira_status` changed vs the DB row, set
     `status_changed_at_jira = now`.
   - Soft-delete (`removed_at = now`) epics/issues not returned this run.
   - Insert `SyncRun(ok: true, ...)`, bump `BoardSnapshot.version`.
5. Broadcast a morph turbo-stream of the rendered board partial to channel
   `board`.

### Page load (`GET /`)

1. `require_login` redirects to `/auth/google_oauth2` if no session.
2. `touch_presence` updates `Presence.last_seen_at`.
3. `BoardController#show` loads active (non-removed) epics and issues with
   eager-loaded associations.
4. `BoardPresenter` produces ordered columns, per-column postit groups,
   staleness buckets, new/done partitioning, warnings.
5. View renders and subscribes via `<%= turbo_stream_from "board" %>`.

### Live update

1. Channel pushes morph stream → Turbo morphs the board DOM.
2. Filter chips reapply on the next animation frame (Stimulus reattaches).
3. Open modals (separate turbo-frames) are untouched by the morph.

### Modal open (click on postit)

1. Turbo Frame request `GET /issues/PG-123`.
2. `IssuesController#show` reads the `Issue` from SQLite, renders
   `_modal.html.erb`.
3. Frame swaps. Modal visible. Closing pops the frame.

## Error handling

- **JIRA sync failure** — caught in `JiraSyncJob`, written to
  `SyncRun(ok: false, error_message)`. One `Rails.logger.error` line. No
  SolidQueue-level retry; the next tick will try again.
- **Unmapped `jira_status`** — `BoardPresenter` appends to `warnings`. View
  shows a yellow chip in the header tray with a hover listing
  `{issue_key, status}` pairs.
- **Missing config keys at boot** — `Config::MissingKey`. Server fails to
  start (Docker healthcheck catches it).
- **OAuth domain mismatch** — flash message + redirect to login. No session
  created.
- **Cold start / empty board** — empty-state message: "No epics yet. Waiting
  for first sync."
- **Stale snapshot banner**, computed from `SyncRun.where(ok: true).last`:
  - ≤ poll cadence: small green dot, tooltip "Updated X ago"
  - 5–30 min: yellow icon
  - \> 30 min: red banner "JIRA sync stalled since HH:MM UTC"
  - thresholds configurable

## Configuration

`config/pgboard.yml` (committed, no secrets):

```yaml
jira:
  base_url_env: JIRA_BASE_URL
  email_env: JIRA_EMAIL
  api_token_env: JIRA_API_TOKEN

auth:
  allowed_domains: ["example.com"]
  allowed_emails: []
  google_client_id_env: GOOGLE_CLIENT_ID
  google_client_secret_env: GOOGLE_CLIENT_SECRET

polling:
  tick_seconds: 60
  active_window_minutes: 5
  idle_interval_minutes: 60

board:
  epic_query: 'project = PG AND labels = "Priority" AND status != Done'
  users:
    - { jira_username: "alice", display_name: "Alice" }
    - { jira_username: "bob",   display_name: "Bob" }
  status_map:
    "To Do":       "new"
    "In Progress": "in_progress"
    "In Review":   "review"
    "Done":        "done"
  new_statuses:   ["new"]
  done_statuses:  ["done"]
  staleness:
    somewhat_days: 7
    really_days:   21
  ignore_staleness_for_new_issues: true
```

`.env` (not committed) — secrets listed above.

## Deployment

Single compose stack, no registry, no local→remote image push. Same workflow
for dev and prod; the only difference is the compose file selected.

- `Dockerfile` — multi-stage, slim ruby + sqlite. Runs Puma; SolidQueue runs
  in-process via the Rails 8 default (`SOLID_QUEUE_IN_PUMA=true`) or as a
  sidecar service depending on what's simpler.
- `Dockerfile.dev` — adds dev gems, mounts code at runtime.
- `docker-compose.yml` (dev) — services: `app` (port 3000, code mounted),
  `chromium` (selenium standalone, used by system tests).
- `docker-compose.prod.yml` — services: `app`, `caddy` (TLS, reverse proxy to
  `app:3000`). Shared host volume for the SQLite files.
- `Taskfile.yml` — common tasks: `dev`, `test`, `console`, `migrate`,
  `redeploy`, `logs`.
- **Hetzner workflow**: ssh into the box, `git pull`, `task redeploy`. The
  redeploy task does `docker compose -f docker-compose.prod.yml up -d --build`
  (rebuilds the image from the freshly-pulled source on the server). No
  registry, no remote image transfer.
- **SQLite volume**: host directory mounted at `/app/storage`, holds
  `production.sqlite3`, `cache.sqlite3`, `queue.sqlite3`, `cable.sqlite3`.
  Backups are out of scope (spec) — it is just a cache.

## Testing

All tests use mock data; no real JIRA is hit.

- **Unit**: `BoardPresenter`, `StalenessCalculator`, `Config` parsing — pure
  Ruby.
- **Service**: `JiraSync` with `jira-ruby` stubbed (WebMock for the underlying
  HTTP, or stubs at the gem's client object).
- **Request**: `BoardController`, `IssuesController`, `SessionsController` —
  seed DB via fixtures, assert rendered HTML and turbo-frame responses.
- **System** (Capybara + Selenium against the `chromium` container, headless
  Chrome):
  - login flow with mocked OmniAuth
  - board renders columns/postits in the expected order
  - filter chips toggle highlight classes
  - postit click opens turbo-frame modal
  - a turbo-stream morph applied while a modal is open does not close it
  - collapsible groups (New/Done) stay in their current open/closed state
    across a morph
- **Fixtures**: `test/fixtures/epics.yml`, `issues.yml`, `sync_runs.yml`. One
  curated set per scenario:
  - happy path
  - stale snapshot (old `SyncRun.ok`)
  - JIRA down (latest `SyncRun.ok = false`)
  - unmapped status (warning tray populated)
  - empty board (cold start)

## Out of scope (explicit)

- Per-user state, write-back to JIRA, ticket editing.
- Multi-project, subtasks.
- Mobile-first UI (revisit later per spec).
- Backups of SQLite.
- Registry-based image distribution.
