# korkban

Read-only Kanban-style board for our JIRA project. See
[`docs/plans/2026-06-09-korkban-design.md`](docs/plans/2026-06-09-korkban-design.md)
for architecture and
[`docs/plans/2026-06-09-korkban-implementation.md`](docs/plans/2026-06-09-korkban-implementation.md)
for the build plan.

## Run locally

```
cp .env.example .env       # fill in JIRA + Google OAuth secrets
cp config/korkban.example.yml config/korkban.yml
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
cd /srv/korkban
git pull
task redeploy
```
