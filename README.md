# pgboard

Read-only Kanban-style board for our JIRA project. See
[`docs/plans/2026-06-09-pgboard-design.md`](docs/plans/2026-06-09-pgboard-design.md)
for architecture and
[`docs/plans/2026-06-09-pgboard-implementation.md`](docs/plans/2026-06-09-pgboard-implementation.md)
for the build plan.

## Run locally

```
cp .env.example .env       # fill in JIRA + Google OAuth secrets
cp config/pgboard.example.yml config/pgboard.yml
task dev                   # http://localhost:3000
```

## Tests

```
task test
```

## Deploy

On the Hetzner VM:

```
ssh hetzner
cd /srv/pgboard
git pull
task redeploy
```
